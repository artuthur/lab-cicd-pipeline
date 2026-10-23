# PKI interne, HTTPS et registre de conteneurs — guide détaillé

> Ce document explique, pas à pas et sans prérequis, comment j'ai mis GitLab en HTTPS avec ma propre autorité de certification, et activé le registre de conteneurs. Il est écrit pour être relu plus tard ou par quelqu'un qui découvre ces notions : chaque notion est expliquée avant d'être utilisée, chaque commande est décortiquée, chaque résultat est interprété.
>
> Dates : étape 1 le 08/10/2026, étape 2 le 09/10/2026.

## Sommaire

1. [Le contexte : pourquoi ne pas rester en HTTP](#1-le-contexte--pourquoi-ne-pas-rester-en-http)
2. [Les notions à connaître](#2-les-notions-à-connaître)
3. [Vue d'ensemble de ce que j'ai construit](#3-vue-densemble-de-ce-que-jai-construit)
4. [Les décisions et leurs raisons](#4-les-décisions-et-leurs-raisons)
5. [La mise en œuvre, rôle par rôle](#5-la-mise-en-œuvre-rôle-par-rôle)
6. [Les commandes exécutées et comment lire leurs résultats](#6-les-commandes-exécutées-et-comment-lire-leurs-résultats)
7. [Les problèmes rencontrés](#7-les-problèmes-rencontrés)
8. [Limites et pistes d'amélioration](#8-limites-et-pistes-damélioration)
9. [Glossaire](#9-glossaire)

---

## 1. Le contexte : pourquoi ne pas rester en HTTP

Mon instance GitLab fonctionnait en **HTTP** (`http://192.168.57.10`). Deux problèmes :

1. **Tout circule en clair sur le réseau** : identifiants, jetons d'accès, code source. Dans un lab privé le risque est faible, mais ce n'est pas une habitude à prendre : en entreprise, rien ne doit circuler en clair.
2. **Le registre de conteneurs (Docker) exige du HTTPS.** Un registre est un serveur où l'on dépose des images Docker (voir section 2.8). Par défaut, Docker refuse de lui parler en HTTP. Le contournement existe, c'est l'option `insecure-registries` du démon Docker, mais elle **désactive la vérification de sécurité** : c'est un raccourci que je voulais éviter.

Je veux donc du vrai HTTPS. Mais HTTPS suppose un **certificat**, et pour qu'un certificat soit accepté, il faut qu'une **autorité de certification** (CA) dont tout le monde se fie l'ait signé. Dans un lab sans nom de domaine public, je dois créer ma propre CA. C'est exactement ce que font les entreprises avec leur PKI interne.

---

## 2. Les notions à connaître

### 2.1 Chiffrement symétrique et asymétrique

- **Symétrique** : une seule clé sert à chiffrer et à déchiffrer (comme une clé de maison que tout le monde se passe). Rapide, mais il faut un moyen sûr de transmettre la clé.
- **Asymétrique** : on a une **paire de clés** liées mathématiquement. La **clé publique** peut être donnée à tout le monde ; la **clé privée** reste secrète. Ce qui est chiffré avec l'une ne se déchiffre qu'avec l'autre. On l'utilise aussi pour **signer** : seul le détenteur de la clé privée peut produire une signature, que tout le monde peut vérifier avec la clé publique.

TLS (section suivante) combine les deux : l'asymétrique sert à s'authentifier et à s'accorder sur une clé, le symétrique chiffre ensuite les échanges.

### 2.2 TLS et HTTPS

**HTTPS = HTTP + TLS.** TLS (Transport Layer Security) apporte trois garanties :

| Garantie | Signification |
|---|---|
| **Confidentialité** | Un tiers qui écoute le réseau ne peut pas lire les échanges |
| **Intégrité** | Les données ne peuvent pas être modifiées en route sans que ça se voie |
| **Authenticité** | Je suis bien en train de parler au vrai serveur, pas à un imposteur |

La troisième est la plus subtile, et c'est elle qui rend les certificats nécessaires.

### 2.3 Certificat (X.509)

Un certificat est une **carte d'identité numérique** d'un serveur. Il contient notamment :

- la **clé publique** du serveur ;
- son **identité** (le nom ou l'adresse pour lequel il est valable) ;
- ses **dates de validité** ;
- l'identité de l'**émetteur** (qui l'a signé) ;
- la **signature** de l'émetteur, qui prouve que le contenu n'a pas été falsifié.

Quand mon navigateur ouvre `https://192.168.57.10`, le serveur présente son certificat. Le navigateur vérifie la signature, les dates et que l'adresse demandée figure bien dans le certificat.

### 2.4 Autorité de certification (CA) et chaîne de confiance

Un certificat que le serveur signerait lui-même ne prouve rien (n'importe qui peut écrire « je suis GitLab »). On fait donc signer le certificat par un **tiers de confiance** : une **autorité de certification (CA)**.

- La CA a sa propre paire de clés. Elle **signe** les certificats des serveurs avec sa clé privée.
- N'importe qui possédant le **certificat public de la CA** peut vérifier que la signature est authentique.
- Le certificat de la CA racine est **auto-signé** (elle se signe elle-même) : c'est le point de départ de la confiance, qu'il faut installer volontairement chez les clients.

Cela forme une **chaîne de confiance** : client → fait confiance à la CA → qui a signé le certificat du serveur → donc le client fait confiance au serveur.

> **Règle d'or : la clé privée de la CA ne doit jamais quitter un endroit sûr.** Quiconque la détient peut fabriquer des certificats que tous mes systèmes accepteront.

### 2.5 Magasin de confiance (trust store)

Chaque système maintient une **liste des CA auxquelles il fait confiance**. Quand on installe un système, cette liste contient déjà les grandes CA publiques (c'est pourquoi les sites publics s'ouvrent sans avertissement). Ma CA interne n'y figure pas : je dois **l'y ajouter moi-même** sur chaque machine qui doit parler à GitLab.

C'est exactement le principe d'une **GPO qui déploie un certificat racine** sur les postes d'un domaine Active Directory. Ici, c'est un rôle Ansible (`ca_trust`) qui joue le rôle de la GPO.

Point de vigilance : il y a plusieurs magasins, et un logiciel n'utilise pas forcément celui du système :

| Logiciel | Où il cherche la confiance |
|---|---|
| `curl`, `git`, Python (Ansible) | Magasin du système (`/etc/ssl/certs`) |
| Navigateur sous Windows | Magasin Windows |
| Démon Docker | `/etc/docker/certs.d/<hôte:port>/ca.crt` (plus précis que le système) |
| GitLab Runner (jobs) | `/etc/gitlab-runner/certs/<hôte>.crt` |
| GitLab lui-même | `/etc/gitlab/trusted-certs/` |

### 2.6 SAN (Subject Alternative Name)

Le **SAN** est la liste des noms ou adresses pour lesquels le certificat est valable. Les clients modernes **ignorent** l'ancien champ « nom commun » (CN) et ne regardent que le SAN. Comme je n'ai pas de DNS dans mon lab, j'accède à GitLab par son adresse IP : le certificat doit donc contenir `IP:192.168.57.10` dans son SAN. Sans ça, même signé par ma CA, il serait refusé (« l'adresse ne correspond pas au certificat »).

### 2.7 Certificat auto-signé, CA interne, Let's Encrypt

| Option | Principe | Pour mon lab |
|---|---|---|
| **Auto-signé simple** | Chaque service signe son propre certificat | Il faut installer **chaque certificat** chez chaque client, un par service |
| **CA interne** | Je crée une CA, elle signe les certificats | J'installe **un seul** certificat (celui de la CA) chez les clients, et tous les certificats futurs sont acceptés automatiquement |
| **Let's Encrypt** | CA publique gratuite | **Impossible** : elle exige un nom de domaine public et joignable depuis Internet |

J'ai choisi la CA interne : c'est la démarche d'une vraie entreprise, et c'est la plus économique à long terme.

### 2.8 Registre de conteneurs et reverse proxy

- Une **image Docker** est un paquet qui contient une application et tout ce dont elle a besoin pour tourner.
- Un **registre** est un serveur qui **stocke et distribue** ces images (comme un dépôt Git, mais pour des images). Une image s'identifie par `<registre>/<projet>/<nom>:<tag>`, par exemple `192.168.57.10:5050/lab/monapp:1.0`.
- GitLab embarque son propre registre (le **Container Registry**), lié à ses projets et à ses comptes. Mon pipeline y déposera les images qu'il construit, et `deploy_target` ira les chercher pour les lancer.
- Un **reverse proxy** (ici Nginx, intégré à GitLab) est un serveur placé **devant** un autre pour recevoir les requêtes à sa place. Le service du registre écoute en local sur le port 5000, sans TLS ; Nginx écoute sur le port 5050 **avec TLS** et lui transmet les requêtes. Ainsi le registre n'a pas à gérer le chiffrement lui-même.

Le registre n'utilise pas ses propres comptes : il délègue l'authentification à GitLab. Quand on se connecte, Docker obtient d'abord un **jeton temporaire** auprès de GitLab, puis le présente au registre. C'est ce que signifie l'en-tête `www-authenticate: Bearer realm="https://192.168.57.10/jwt/auth",service="container_registry"` vu plus loin.

---

## 3. Vue d'ensemble de ce que j'ai construit

```
   ┌────────────────────────────────────────────────┐
   │ CA interne « Lab CI/CD Internal CA »            │
   │ clé privée : ~/.lab-pki/lab-cicd-pipeline/      │
   │ (sur WSL2, jamais copiée sur une VM, hors Git)  │
   └───────────────────────┬────────────────────────┘
                           │ signe
                           ▼
   ┌────────────────────────────────────────────────┐
   │ Certificat serveur, SAN = IP:192.168.57.10      │
   │ déposé sur la VM « gitlab »                      │
   └────────────────────────────────────────────────┘

   Ports de la VM « gitlab » :
     80   → redirige vers 443
     443  → interface et API GitLab (HTTPS)
     5050 → registre de conteneurs (HTTPS, via Nginx)
     5000 → registre (local uniquement, sans TLS, derrière Nginx)

   Qui fait confiance à la CA (en recevant son certificat public) :
     • les 3 VMs, magasin système            (rôle ca_trust)
     • GitLab, magasin interne               (rôle gitlab)
     • Docker de runner et deploy_target     (rôle docker_registry_trust)
     • GitLab Runner, pour les jobs          (rôle runner)
     • Windows, donc mon navigateur          (import manuel avec certutil)
```

---

## 4. Les décisions et leurs raisons

| Décision | Raison |
|---|---|
| **CA interne** plutôt que certificats auto-signés | Un seul certificat à distribuer, tous les futurs services sont couverts d'office |
| **Accès par IP** (SAN `IP:`) plutôt que par nom DNS | Pas de DNS dans le lab ; évite de modifier les fichiers `hosts` de chaque machine. Amélioration possible plus tard |
| **PKI générée sur WSL2**, dans `~/.lab-pki/` | La clé privée de la CA ne quitte jamais mon poste de contrôle, n'est jamais versionnée, et se trouve sur le système de fichiers natif de WSL2 où les permissions Unix (`0600`) sont réellement appliquées (sur `/mnt/c` elles seraient affichées en `777`, voir le premier projet) |
| **Let's Encrypt désactivé** dans GitLab | GitLab tente de l'activer seul dès que l'URL est en `https` ; il échouerait faute de domaine public |
| **Registre sur le port 5050** de la même IP | Réutilise le même certificat, sans DNS ni second nom |
| **`/etc/docker/certs.d/`** plutôt que le magasin du système pour Docker | Mécanisme officiel, ciblé sur un registre précis, relu à chaque connexion sans redémarrer Docker |
| **Rôle partagé `docker_registry_trust`** | `runner` et `deploy_target` ont besoin exactement de la même chose : pas de duplication |
| **Deux étapes** (GitLab d'abord, runner/Docker ensuite) | Permet de valider chaque couche séparément avant de passer à la suivante |

---

## 5. La mise en œuvre, rôle par rôle

### 5.1 Variables partagées : `inventory/group_vars/all.yml`

```yaml
pki_dir: "{{ lookup('ansible.builtin.env', 'HOME') }}/.lab-pki/lab-cicd-pipeline"
gitlab_server_ip: "{{ hostvars['gitlab'].ansible_host }}"
gitlab_registry_port: 5050
gitlab_registry_hostport: "{{ gitlab_server_ip }}:{{ gitlab_registry_port }}"
```

- Le fichier `all.yml` s'applique à **tous** les hôtes, y compris la machine locale (WSL2) où tourne le rôle `pki`. C'est pourquoi `pki_dir` y est défini : plusieurs rôles en ont besoin.
- `lookup('ansible.builtin.env', 'HOME')` lit la variable d'environnement `HOME`. Les `lookup` s'exécutent **sur le nœud de contrôle**, donc on obtient le dossier personnel de WSL2.
- `hostvars['gitlab'].ansible_host` récupère l'IP déclarée dans l'inventaire : l'adresse n'est écrite qu'à un seul endroit.

### 5.2 Rôle `pki` : fabriquer la CA et le certificat (sur WSL2)

Ce rôle s'exécute sur `localhost`, pas sur les VMs (play avec `connection: local`). Il enchaîne six opérations, qui reprennent exactement les étapes d'une vraie PKI :

| # | Module Ansible (`community.crypto`) | Ce qu'il fait |
|---|---|---|
| 1 | `openssl_privatekey` (CA) | Génère la paire de clés de la CA (RSA 4096 bits), fichier `lab-ca.key` en mode `0600` |
| 2 | `openssl_csr` (CA) | Prépare la **demande de certificat** (CSR) de la CA, avec `CA:TRUE` (« je peux signer d'autres certificats ») et les usages `keyCertSign` / `cRLSign` |
| 3 | `x509_certificate`, `provider: selfsigned` | La CA **se signe elle-même** : produit `lab-ca.crt` (valable 10 ans), le point de départ de la confiance |
| 4 | `openssl_privatekey` (serveur) | Génère la paire de clés du serveur (RSA 2048 bits) |
| 5 | `openssl_csr` (serveur) | Demande de certificat du serveur, avec le **SAN `IP:192.168.57.10`**, `CA:FALSE` (« je ne peux pas signer d'autres certificats ») et l'usage `serverAuth` (« je sers à authentifier un serveur ») |
| 6 | `x509_certificate`, `provider: ownca` | **La CA signe** la demande du serveur avec sa clé privée : produit `gitlab.crt` (valable 825 jours) |

Une **CSR** (*Certificate Signing Request*) est une demande de certificat : « voici ma clé publique et mon identité, signe-moi ». La clé privée du serveur n'est jamais transmise à la CA, seule la clé publique figure dans la demande.

Tous ces modules sont **idempotents** : s'ils trouvent déjà un fichier conforme aux paramètres, ils ne le régénèrent pas. Relancer le playbook ne change donc pas les certificats.

Résultat dans `~/.lab-pki/lab-cicd-pipeline/` :

```
lab-ca.key   lab-ca.csr   lab-ca.crt      ← la CA (la .key est le secret absolu)
gitlab.key   gitlab.csr   gitlab.crt      ← le serveur
```

### 5.3 Rôle `ca_trust` : distribuer la CA aux VMs

```yaml
- name: Déposer le certificat de la CA interne dans le magasin de confiance du système
  ansible.builtin.copy:
    src: "{{ pki_dir }}/lab-ca.crt"
    dest: /usr/local/share/ca-certificates/lab-ca.crt
  notify: Mettre à jour le magasin de certificats
```

- `copy` avec `src` lit le fichier **sur le nœud de contrôle** et le dépose sur la VM.
- Le dossier `/usr/local/share/ca-certificates/` est celui où Debian attend les CA ajoutées à la main (le fichier doit se terminer par `.crt`).
- Le handler lance `update-ca-certificates`, qui reconstruit la liste officielle des CA du système (`/etc/ssl/certs/`) en y intégrant la mienne.
- Le déploiement est suivi d'un `meta: flush_handlers`, pour que cette mise à jour soit **effective immédiatement** : les tâches suivantes en ont besoin (notion déjà rencontrée avec GitLab, voir le journal du 06/10/2026).

### 5.4 Rôle `gitlab` : passer en HTTPS et activer le registre

**Ordre des opérations**, qui compte : les certificats sont déposés **avant** la reconfiguration. Sinon Nginx démarrerait avec une URL HTTPS sans certificat et refuserait de démarrer.

1. Dépôt du certificat serveur et de la clé dans `/etc/gitlab/ssl/`. GitLab impose le nom de fichier `<hôte de external_url>.crt` : ici `192.168.57.10.crt` et `192.168.57.10.key`. La clé est en mode `0600` et la tâche utilise `no_log: true` pour ne jamais afficher son contenu dans les logs.
2. Dépôt de la CA dans `/etc/gitlab/trusted-certs/`. GitLab embarque **son propre** bundle de CA, indépendant de celui du système ; sans ça, ses composants internes refuseraient son propre certificat signé par une CA inconnue.
3. Le fichier de configuration `gitlab.rb` :

```ruby
external_url 'https://192.168.57.10'

letsencrypt['enable'] = false
nginx['ssl_certificate'] = "/etc/gitlab/ssl/192.168.57.10.crt"
nginx['ssl_certificate_key'] = "/etc/gitlab/ssl/192.168.57.10.key"
nginx['redirect_http_to_https'] = true

registry_external_url 'https://192.168.57.10:5050'
registry_nginx['ssl_certificate'] = "/etc/gitlab/ssl/192.168.57.10.crt"
registry_nginx['ssl_certificate_key'] = "/etc/gitlab/ssl/192.168.57.10.key"
```

| Ligne | Rôle |
|---|---|
| `external_url 'https://...'` | L'adresse publique de GitLab. Le passage en `https` active TLS dans Nginx |
| `letsencrypt['enable'] = false` | Empêche GitLab de tenter d'obtenir seul un certificat Let's Encrypt |
| `nginx['ssl_certificate*']` | Chemins du certificat et de la clé à utiliser |
| `nginx['redirect_http_to_https']` | Redirige `http://` vers `https://` (sans ça, le port 80 n'est plus écouté du tout) |
| `registry_external_url` | **Active** le registre, avec son URL publique (port 5050) |
| `registry_nginx['ssl_certificate*']` | Même certificat pour la façade du registre |

4. Un `meta: flush_handlers` déclenche la reconfiguration de GitLab (`gitlab-ctl reconfigure`) immédiatement.
5. Pare-feu : ouverture des ports 80, 443 et 5050.

### 5.5 Rôle `docker_registry_trust` : Docker fait confiance à la CA

```yaml
- ansible.builtin.file:
    path: "/etc/docker/certs.d/192.168.57.10:5050"
    state: directory
- ansible.builtin.copy:
    src: "{{ pki_dir }}/lab-ca.crt"
    dest: "/etc/docker/certs.d/192.168.57.10:5050/ca.crt"
```

Le nom du dossier doit être **exactement** `<hôte>:<port>` du registre. Docker le consulte à chaque connexion à ce registre, sans redémarrage. Appliqué à `runner` (qui construira et poussera les images) et à `deploy_target` (qui les téléchargera).

### 5.6 Rôle `runner` : adaptations

- Création de `/etc/gitlab-runner/certs/` et dépôt de la CA sous le nom `192.168.57.10.crt` : c'est le nom que GitLab Runner exige (`<hôte du serveur>.crt`). Les conteneurs de jobs s'en servent pour cloner le dépôt en HTTPS.
- L'URL de l'API passe en `https://` (`inventory/group_vars/ci_runners/vars.yml`).
- Comme le runner existant était enregistré avec l'ancienne URL HTTP et que ma condition d'idempotence saute l'enregistrement dès qu'un jeton existe, j'ai **reconstruit la VM `runner`** (`vagrant destroy runner -f` puis `vagrant up runner`) : elle s'est réenregistrée proprement en HTTPS, ce qui a aussi servi de test de reproductibilité.

### 5.7 Ordre des plays dans `site.yml`

1. `pki` sur `localhost` (il faut que la CA existe avant toute distribution)
2. `common` + `ca_trust` sur les 3 VMs
3. `gitlab` sur la VM GitLab
4. `runner` + `docker_registry_trust`
5. `deploy_target` + `docker_registry_trust`

---

## 6. Les commandes exécutées et comment lire leurs résultats

### 6.1 Préparation

```bash
ansible-galaxy collection install -r requirements.yml
```
Installe les collections Ansible déclarées dans `requirements.yml` (dont `community.crypto`, qui fournit les modules de la PKI).

```bash
python3 -c "import cryptography; print(cryptography.__version__)"
```
Vérifie que la bibliothèque Python `cryptography` est installée sur WSL2 : les modules `community.crypto` en ont besoin. Si l'import échoue, il faut `sudo apt install python3-cryptography`. Un numéro de version en sortie = c'est bon.

```bash
ansible-playbook site.yml --ask-vault-pass
```
Au premier passage, les tâches de la PKI et de `ca_trust` sont en `changed` (les fichiers sont créés), et le `gitlab-ctl reconfigure` est long (plusieurs minutes) car GitLab doit basculer Nginx en HTTPS et créer le service du registre.

### 6.2 Importer la CA dans Windows (pour le navigateur)

```powershell
certutil -addstore -f "ROOT" "C:\chemin\vers\lab-ca.crt"
```
- `certutil` est l'outil Windows de gestion des certificats ; `-addstore` ajoute au magasin nommé `ROOT` (« Autorités de certification racines de confiance »), `-f` force l'opération. À lancer dans un PowerShell **administrateur**.
- Il faut ensuite **redémarrer le navigateur** (il charge le magasin au démarrage). L'avertissement de sécurité a alors disparu.

### 6.3 Test 1 : GitLab répond-il en HTTPS avec un certificat valide ?

```bash
curl -I --cacert ~/.lab-pki/lab-cicd-pipeline/lab-ca.crt https://192.168.57.10
```

| Élément | Signification |
|---|---|
| `curl` | Outil pour faire des requêtes HTTP depuis le terminal |
| `-I` | N'affiche que les **en-têtes** de la réponse (requête de type `HEAD`) |
| `--cacert <fichier>` | Utilise **cette CA** comme référence de confiance, à la place du magasin du système |

Résultat obtenu :

```
HTTP/2 302
location: https://192.168.57.10/users/sign_in
strict-transport-security: max-age=63072000
```

- **`HTTP/2`** : la connexion TLS s'est établie (le certificat a été **vérifié** avec ma CA ; sinon curl aurait refusé).
- **`302`** : redirection. GitLab renvoie un visiteur non connecté vers la page de connexion (`location`). Ce n'est pas une erreur, c'est le comportement normal.
- **`strict-transport-security`** (HSTS) : GitLab demande au navigateur de n'utiliser que HTTPS pour ce site pendant 63 072 000 secondes (2 ans).

### 6.4 Test 2 : le registre répond-il en HTTPS ?

```bash
curl -I --cacert ~/.lab-pki/lab-cicd-pipeline/lab-ca.crt https://192.168.57.10:5050/v2/
```
`/v2/` est le point d'entrée de l'API des registres Docker. Résultat attendu et obtenu :

```
HTTP/2 401
www-authenticate: Bearer realm="https://192.168.57.10/jwt/auth",service="container_registry"
```

- **`401 Unauthorized` est le bon résultat** : le registre existe, répond en TLS, et exige une authentification. Un `200` serait même inquiétant (registre ouvert à tous).
- **`www-authenticate: Bearer realm=...`** : le registre indique à Docker où obtenir un jeton (`realm`, l'URL de GitLab) et pour quel service (`service`).
- **`service="container_registry"`** : c'est bien le registre qui répond.

### 6.5 Test 3 : les VMs font-elles confiance à la CA toute seules ?

```bash
ansible ci_runners -m command -a "curl -sI https://192.168.57.10" --ask-vault-pass
```
- `ansible ci_runners` : cible le groupe `ci_runners`.
- `-m command` : utilise le module `command` (exécute une commande sur la cible).
- `-a "..."` : les arguments, ici la commande `curl`.
- `--ask-vault-pass` : sur une commande ad hoc aussi, Ansible charge tous les `group_vars`, donc le Vault, et demande son mot de passe.
- Dans le `curl`, **pas de `--cacert`** : c'est le système de la VM qui doit faire confiance, donc `ca_trust` est mis à l'épreuve.

Premier résultat : **échec**, `rc=60`. Le code 60 de curl signifie « le certificat du serveur n'a pas pu être vérifié ». Cause : j'avais oublié d'ajouter le rôle `ca_trust` dans `site.yml`, il n'avait donc jamais été appliqué. Après correction et nouveau passage du playbook, toutes les VMs répondent `HTTP/2 302`. Leçon : le test qui échoue est **une information précieuse**, il a révélé un oubli que les autres tests ne pouvaient pas voir (ils utilisaient tous `--cacert`).

> **Détail de lecture** : `curl -s` (silencieux) masque aussi les messages d'erreur. Pour diagnostiquer, il vaut mieux `curl -sSI` : `-S` ré-affiche les erreurs malgré `-s`.

### 6.6 Test 4 : le registre fonctionne-t-il vraiment ?

```bash
ansible gitlab -m command -a "gitlab-ctl status registry" --become --ask-vault-pass
```
`gitlab-ctl status <service>` interroge le gestionnaire de services interne de GitLab. `--become` exécute en tant que root.
Résultat : `run: registry: (pid 1263) ...` : le service tourne (`run`) avec le processus 1263.

```bash
ansible gitlab -m command -a "curl -si http://127.0.0.1:5000/v2/" --ask-vault-pass
```
Interroge le registre **directement, sans passer par Nginx** (adresse locale `127.0.0.1`, port 5000, sans TLS), ce qui isole le registre du reste. Résultat : `401` avec `Docker-Distribution-Api-Version: registry/2.0` (la signature d'un registre Docker) et `service="container_registry"`.

```bash
ansible gitlab -m shell -a "ss -tlnp | grep -E ':(5000|5050) '" --become --ask-vault-pass
```
- On utilise le module `shell` (et non `command`) parce que la commande contient un **pipe** `|`, que `command` ne sait pas interpréter.
- `ss` liste les connexions réseau ; `-t` TCP, `-l` en écoute (*listening*), `-n` adresses numériques, `-p` affiche le **processus** concerné.
- `grep -E ':(5000|5050) '` ne garde que les lignes des ports 5000 ou 5050.

Résultat :

```
LISTEN  0.0.0.0:5050     users:(("nginx",...))
LISTEN  127.0.0.1:5000   users:(("registry",...))
```

- **`0.0.0.0:5050` → nginx** : Nginx écoute sur le port 5050 sur **toutes** les interfaces réseau (accessible depuis l'extérieur).
- **`127.0.0.1:5000` → registry** : le registre n'écoute que **localement**, donc il n'est pas joignable de l'extérieur sans passer par Nginx. C'est exactement l'architecture « registre derrière un reverse proxy TLS » voulue.

### 6.7 Test 5 : Docker fait-il confiance à la CA ?

```bash
ansible runner -m command -a "docker pull 192.168.57.10:5050/test/inexistant:latest" --become --ask-vault-pass
```
J'essaie de télécharger une image **qui n'existe pas**. Ce qui m'intéresse, c'est **le type d'erreur** :

- `x509: certificate signed by unknown authority` → Docker ne fait pas confiance à la CA (échec côté TLS) ;
- `denied` / `unauthorized` → la connexion TLS a **réussi**, et c'est l'autorisation qui refuse (normal : je ne suis pas connecté).

Résultat sur `runner` et `deploy_target` :
```
Head "https://192.168.57.10:5050/v2/test/inexistant/manifests/latest": denied: access forbidden
```
- `Head` : Docker envoie d'abord une requête `HEAD` pour savoir si l'image existe.
- **`denied: access forbidden`** : pas d'erreur `x509`, donc le TLS a fonctionné. Docker fait bien confiance à la CA grâce au dossier `certs.d`. Le refus est un refus d'autorisation, ce qui est le comportement attendu pour un utilisateur anonyme. (Le registre répond « refusé » plutôt que « introuvable » pour ne pas révéler quels projets existent.)

### 6.8 Test 6 : connexion complète au registre

```bash
ssh -i ~/.ssh/lab-cicd-pipeline/private_key_runner vagrant@192.168.57.11
sudo docker login 192.168.57.10:5050
```
Je me connecte à la VM puis lance `docker login`, qui me **demande** le mot de passe : de cette façon, il n'apparaît dans aucune commande ni historique. J'utilise comme identifiant `arthur` et comme mot de passe mon **jeton d'accès personnel** (`glpat-...`, de portée `api`, qui couvre l'accès au registre).

Résultat : `Login Succeeded`. C'est le test le plus complet : il prouve en une fois le TLS, la confiance en la CA, l'authentification via GitLab (le jeton temporaire) et le fonctionnement du registre.

Le message `WARNING! Your password will be stored unencrypted in /root/.docker/config.json` indique que Docker stocke les identifiants **simplement encodés** dans ce fichier, faute de « credential helper ». Acceptable pour un lab ; dans un pipeline, on utilisera plutôt un jeton temporaire propre au job (`CI_JOB_TOKEN`), qui expire à la fin du job.

---

## 7. Les problèmes rencontrés

| Problème | Cause | Résolution |
|---|---|---|
| `curl` des VMs : `rc=60` | Le rôle `ca_trust` n'était pas listé dans `site.yml`, la CA n'était donc installée sur aucune VM | Ajout du rôle puis relance : toutes les VMs répondent `HTTP/2 302` |
| Le port 5050 annonçait `service="dependency_proxy"` au premier test | Cet en-tête est celui du *Dependency Proxy*, une autre fonction servie par l'application GitLab et non par le registre. Je n'ai pas identifié la cause exacte : aucune configuration du registre n'a changé entre les deux tests, et un nouveau test après redémarrage des VMs a renvoyé `service="container_registry"`. Probablement un état transitoire après la reconfiguration | Vérification en trois temps (service actif, registre interrogé en direct, ports en écoute) puis nouveau test |
| Runner enregistré avec l'ancienne URL HTTP | Son `config.toml` contenait toujours l'URL d'origine, et ma condition d'idempotence saute l'enregistrement dès qu'un jeton existe | Reconstruction de la VM `runner` |

Réflexe retenu : **ne pas ignorer un détail inattendu dans une réponse**, même quand le test global « passe » : l'en-tête `dependency_proxy` aurait pu masquer un registre mal routé.

---

## 8. Limites et pistes d'amélioration

- **Durée de vie du certificat serveur : 825 jours.** Il faudra prévoir son renouvellement, que je n'ai pas automatisé.
- **La clé privée de la CA** est un fichier sur mon poste (`~/.lab-pki/...`), protégé par ses permissions mais pas chiffré. Dans une vraie entreprise elle serait protégée beaucoup plus fortement (module matériel, CA racine hors ligne, CA intermédiaire pour les opérations courantes).
- **Accès par IP** : un nom DNS (par exemple `gitlab.lab.local`) serait plus propre et permettrait de changer d'adresse sans réémettre le certificat.
- **HSTS** : mon navigateur a mémorisé que ce site ne se visite qu'en HTTPS pendant 2 ans. Revenir en HTTP un jour poserait un problème côté navigateur.
- **Identifiants Docker stockés en clair** dans `/root/.docker/config.json` sur la VM de test : à ne pas reproduire en production.

---

## 9. Glossaire

| Terme | Définition |
|---|---|
| **TLS** | Protocole qui chiffre et authentifie les communications réseau ; c'est le « S » de HTTPS |
| **Certificat X.509** | Carte d'identité numérique : clé publique, identité, validité, signature de l'émetteur |
| **CA** | Autorité de certification : tiers de confiance qui signe les certificats |
| **Chaîne de confiance** | Enchaînement client → CA de confiance → certificat du serveur |
| **Auto-signé** | Certificat signé par sa propre clé privée (cas du certificat racine d'une CA) |
| **CSR** | *Certificate Signing Request* : demande de certificat envoyée à une CA |
| **SAN** | Liste des noms/adresses pour lesquels un certificat est valable |
| **Magasin de confiance** | Liste des CA auxquelles un système fait confiance |
| **PKI** | Infrastructure de gestion de clés : CA, certificats, distribution de la confiance |
| **Clé privée / publique** | Paire de clés asymétriques : la privée reste secrète, la publique se partage |
| **Registre de conteneurs** | Serveur de stockage et de distribution d'images Docker |
| **Reverse proxy** | Serveur placé devant un autre pour recevoir les requêtes à sa place (ici Nginx) |
| **HSTS** | En-tête qui oblige le navigateur à n'utiliser que HTTPS pour un site |
| **Idempotence** | Propriété d'une opération qui, répétée, donne le même résultat sans rien changer de plus |
