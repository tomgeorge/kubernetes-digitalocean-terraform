###############################################################################
#
# A simple K8s cluster in DO
#
###############################################################################


###############################################################################
#
# Get variables from command line or environment
#
###############################################################################


variable "do_token" {}

variable "do_region" {
    default = "nyc3"
}

variable "domain_name" {}


variable "ssh_fingerprint" {}
variable "ssh_private_key" {
    default = "~/.ssh/id_rsa"
}

variable "path_to_flux_deploy_private_key" {}

variable "number_of_masters" {
	default = "1"
}

variable "number_of_workers" {
	default = "2"
}

variable "k8s_version" {
	default = "v1.15.2"
}

variable "cni_version" {
	default = "v0.7.1"
}

variable "prefix" {
    default = ""
}

variable "size_master" {
    default = "1gb"
}

variable "size_worker" {
    default = "1gb"
}

variable "deploy_flux" {}


###############################################################################
#
# Specify provider
#
###############################################################################


provider "digitalocean" {
    token = "${var.do_token}"
}


###############################################################################
#
# Master host
#
###############################################################################


resource "digitalocean_droplet" "k8s_master" {
    image = "coreos-stable"
    name = "master.${var.domain_name}"
    region = "${var.do_region}"
    private_networking = true
    size = "${var.size_master}"
    ssh_keys = ["${split(",", var.ssh_fingerprint)}"]

    provisioner "file" {
        source = "./00-master.sh"
        destination = "/tmp/00-master.sh"
        connection {
            type = "ssh",
            user = "core",
            private_key = "${file(var.ssh_private_key)}"
        }
    }

    provisioner "file" {
        source = "./install-kubeadm.sh"
        destination = "/tmp/install-kubeadm.sh"
        connection {
            type = "ssh",
            user = "core",
            private_key = "${file(var.ssh_private_key)}"
        }
    }

    # Install dependencies and set up cluster
    provisioner "remote-exec" {
        inline = [
            "export K8S_VERSION=\"${var.k8s_version}\"",
            "export CNI_VERSION=\"${var.cni_version}\"",
						"export DOMAIN_NAME=\"${var.domain_name}\"",
            "chmod +x /tmp/install-kubeadm.sh",
            "sudo -E /tmp/install-kubeadm.sh",
            "export MASTER_PRIVATE_IP=\"${self.ipv4_address_private}\"",
            "export MASTER_PUBLIC_IP=\"${self.ipv4_address}\"",
            "chmod +x /tmp/00-master.sh",
            "sudo -E /tmp/00-master.sh"
        ]
        connection {
            type = "ssh",
            user = "core",
            private_key = "${file(var.ssh_private_key)}"
        }
    }

    # copy secrets to local
    provisioner "local-exec" {
        command =<<EOF
            scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${var.ssh_private_key} core@${digitalocean_droplet.k8s_master.ipv4_address}:"/tmp/kubeadm_join /etc/kubernetes/admin.conf" ${path.module}/secrets/
            sed -i.bak "s/${self.ipv4_address_private}/${self.ipv4_address}/" ${path.module}/secrets/admin.conf
EOF
    }

}

###############################################################################
#
# Worker hosts
#
###############################################################################


resource "digitalocean_droplet" "k8s_worker" {
    count = "${var.number_of_workers}"
    image = "coreos-stable"
    name = "${var.prefix}${format("worker-%02d", count.index + 1)}.${var.domain_name}"
    region = "${var.do_region}"
    size = "${var.size_worker}"
    private_networking = true
    # user_data = "${data.template_file.worker_yaml.rendered}"
    ssh_keys = ["${split(",", var.ssh_fingerprint)}"]
    depends_on = ["digitalocean_droplet.k8s_master"]

    # Start kubelet
    provisioner "file" {
        source = "./01-worker.sh"
        destination = "/tmp/01-worker.sh"
        connection {
            type = "ssh",
            user = "core",
            private_key = "${file(var.ssh_private_key)}"
        }
    }

    provisioner "file" {
        source = "./install-kubeadm.sh"
        destination = "/tmp/install-kubeadm.sh"
        connection {
            type = "ssh",
            user = "core",
            private_key = "${file(var.ssh_private_key)}"
        }
    }

    provisioner "file" {
        source = "./secrets/kubeadm_join"
        destination = "/tmp/kubeadm_join"
        connection {
            type = "ssh",
            user = "core",
            private_key = "${file(var.ssh_private_key)}"
        }
    }

    # Install dependencies and join cluster
    provisioner "remote-exec" {
        inline = [
            "export K8S_VERSION=\"${var.k8s_version}\"",
            "export CNI_VERSION=\"${var.cni_version}\"",
            "chmod +x /tmp/install-kubeadm.sh",
            "sudo -E /tmp/install-kubeadm.sh",
            "export NODE_PRIVATE_IP=\"${self.ipv4_address_private}\"",
            "chmod +x /tmp/01-worker.sh",
            "sudo -E /tmp/01-worker.sh"
        ]
        connection {
            type = "ssh",
            user = "core",
            private_key = "${file(var.ssh_private_key)}"
        }
    }

    /* provisioner "local-exec" { */
    /*     when = "destroy" */
    /*     command = <<EOF */
/* export KUBECONFIG=${path.module}/secrets/admin.conf */
/* kubectl drain --delete-local-data --force --ignore-daemonsets ${self.name} */
/* kubectl delete nodes/${self.name} */
/* EOF */
    /* } */
}

# use kubeconfig retrieved from master

resource "digitalocean_record" "wildcard_record" {
    name = "*"
    type = "CNAME"
    ttl = "43200"
    value = "${var.domain_name}."
    domain = "${var.domain_name}"
}

resource "digitalocean_record" "master_record" {
    name = "@"
    type = "A"
    ttl = "3600"
    value = "${digitalocean_droplet.k8s_master.ipv4_address}"
    domain = "${var.domain_name}"
}

resource "null_resource" "do_secret" {
    depends_on = ["digitalocean_droplet.k8s_worker"]
    provisioner "local-exec" {
        command = <<EOF
            export KUBECONFIG=${path.module}/secrets/admin.conf
            sed -e "s/\$DO_ACCESS_TOKEN/${var.do_token}/" < ${path.module}/03-do-secret.yaml > ./secrets/03-do-secret.rendered.yaml
            until kubectl get pods 2>/dev/null; do printf '.'; sleep 5; done
            kubectl create -f ./secrets/03-do-secret.rendered.yaml
EOF
    }
}

resource "null_resource" "deploy_istio_crds" {
    depends_on = ["digitalocean_droplet.k8s_worker"]
    provisioner "local-exec" {
        command = <<EOF
            export KUBECONFIG=${path.module}/secrets/admin.conf
            until kubectl get pods 2>/dev/null; do printf '.'; sleep 5; done
            kubectl apply -f deploy/istio/
EOF
    }
}

resource "null_resource" "git_deploy_key" {
    depends_on = ["digitalocean_droplet.k8s_worker"]
    provisioner "local-exec" {
        command = <<EOF
            export KUBECONFIG=${path.module}/secrets/admin.conf
            until kubectl get pods 2>/dev/null; do printf '.'; sleep 5; done
            kubectl create secret generic flux-git-deploy --from-file=identity=${var.path_to_flux_deploy_private_key}
EOF
    }
}

resource "null_resource" "install_flux" {
    depends_on = ["digitalocean_droplet.k8s_worker"]
    count = "${var.deploy_flux}"
    provisioner "local-exec" {
        command = <<EOF
            export KUBECONFIG=${path.module}/secrets/admin.conf
            until kubectl get pods 2>/dev/null; do printf '.'; sleep 5; done
            kubectl apply -f deploy/flux
EOF
    }
}
