# Exécuté via `gitlab-rails runner` (rôle gitlab, tâche d'initialisation admin).
# Aucun secret en dur ici : tout passe par variables d'environnement,
# fournies par Ansible au moment de l'exécution uniquement.

root = User.find_by(username: 'root')
root.password = ENV.fetch('GITLAB_ROOT_PASSWORD')
root.password_confirmation = ENV.fetch('GITLAB_ROOT_PASSWORD')
root.password_automatically_set = false
root.save!

admin_username = ENV.fetch('GITLAB_ADMIN_USERNAME')

unless User.find_by(username: admin_username)
  # Users::CreateService vérifie les droits de l'acteur (1er argument) avant
  # d'autoriser admin: true — avec nil (pas d'acteur, cas du bootstrap), ça échoue
  # systématiquement (Gitlab::Access::AccessDeniedError). Approche officiellement
  # documentée par GitLab pour ce cas précis : construire l'utilisateur directement
  # et assigner explicitement son namespace personnel (plus automatique par défaut
  # depuis l'introduction du concept d'Organisation).
  user = User.new(
    username: admin_username,
    name: ENV.fetch('GITLAB_ADMIN_NAME'),
    email: ENV.fetch('GITLAB_ADMIN_EMAIL'),
    password: ENV.fetch('GITLAB_ADMIN_PASSWORD'),
    password_confirmation: ENV.fetch('GITLAB_ADMIN_PASSWORD')
  )
  user.assign_personal_namespace(Organizations::Organization.default_organization)
  user.admin = true
  user.skip_confirmation!
  user.save!
end