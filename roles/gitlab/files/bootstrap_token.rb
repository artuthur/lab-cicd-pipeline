# Exécuté via `gitlab-rails runner` (rôle gitlab).
# Crée un jeton d'accès personnel dont la valeur est choisie à l'avance (elle vient du
# Vault Ansible, par variable d'environnement), au lieu d'être générée par GitLab.
# Procédure documentée par GitLab ("Create a personal access token programmatically").
#
# Affiche CREATED ou EXISTS : Ansible s'en sert pour savoir s'il a changé quelque chose.

user = User.find_by!(username: ENV.fetch('GITLAB_ADMIN_USERNAME'))
token_value = ENV.fetch('GITLAB_API_TOKEN')

if PersonalAccessToken.find_by_token(token_value)
  puts 'EXISTS'
else
  token = user.personal_access_tokens.build(
    name: 'ansible-automation',
    scopes: [:api],
    expires_at: 360.days.from_now.to_date
  )
  # Depuis l'introduction des Organisations, certains objets exigent d'en désigner une.
  if token.respond_to?(:organization=)
    token.organization = Organizations::Organization.default_organization
  end
  token.set_token(token_value)
  token.save!
  puts 'CREATED'
end