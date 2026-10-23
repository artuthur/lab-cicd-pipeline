Vagrant.configure("2") do |config|

  # Box multi-provider (contrairement à debian/bookworm64, souvent VirtualBox-only)
  config.vm.box = "generic/debian12"

  config.vm.provision "shell", inline: <<-SHELL
    apt-get update -qq
  SHELL

  # --- VM 1 : GitLab CE (dépôt Git + CI/CD + registre Docker) ---
  config.vm.define "gitlab" do |gitlab|
    gitlab.vm.hostname = "gitlab"
    gitlab.vm.network "private_network", ip: "192.168.57.10"
    gitlab.vm.provider "vmware_desktop" do |v|
      v.gui = false
      v.vmx["memsize"] = "4096"
      v.vmx["numvcpus"] = "2"
    end
  end

  # --- VM 2 : GitLab Runner (exécuteur Docker) ---
  config.vm.define "runner" do |runner|
    runner.vm.hostname = "runner"
    runner.vm.network "private_network", ip: "192.168.57.11"
    runner.vm.provider "vmware_desktop" do |v|
      v.gui = false
      v.vmx["memsize"] = "2048"
      v.vmx["numvcpus"] = "2"
    end
  end

  # --- VM 3 : Cible de déploiement ---
  config.vm.define "deploy_target" do |target|
    target.vm.hostname = "deploy-target"
    target.vm.network "private_network", ip: "192.168.57.12"
    target.vm.provider "vmware_desktop" do |v|
      v.gui = false
      v.vmx["memsize"] = "1024"
      v.vmx["numvcpus"] = "1"
    end
  end

end