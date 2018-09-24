variable "do_token" {}

variable "ssh_fingerprint" {}
variable "ssh_private_key" {
  default = "~/.ssh/id_rsa"
}

variable "prefix" {
  default = ""
}

variable "region" {
  default = "nyc3"
}

provider "digitalocean" {
  token = "${var.do_token}"
}

resource "digitalocean_droplet" "forward_proxy" {
  image = "coreos-stable"
  name = "${var.prefix}k8s-forward-proxy"
  size = "1gb"
  ssh_keys = ["${split(",", var.ssh_fingerprint)}"]
  region = "${var.region}"

  provisioner "remote-exec" {
      inline = [
        "mkdir -p /home/core/forward-proxy/"
      ]
      connection {
          type = "ssh",
          user = "core",
          private_key = "${file(var.ssh_private_key)}"
      }
  }
  provisioner "file" {
    source = "Dockerfile"
    destination = "/home/core/forward-proxy/Dockerfile"
    connection {
      type = "ssh",
      user = "core",
      private_key = "${file(var.ssh_private_key)}"
    }
  }
  provisioner "file" {
    source = "nginx.conf"
    destination = "/home/core/forward-proxy/nginx.conf"
    connection {
      type = "ssh",
      user = "core",
      private_key = "${file(var.ssh_private_key)}"
    }
  }
  provisioner "file" {
    source = "Makefile"
    destination = "/home/core/forward-proxy/Makefile"
    connection {
      type = "ssh",
      user = "core",
      private_key = "${file(var.ssh_private_key)}"
    }
  }
  provisioner "remote-exec" {
      inline = [
        "docker run -ti --rm -v /opt/bin:/out ubuntu:14.04 /bin/bash -c \"apt-get update && apt-get -y install make && cp /usr/bin/make /out/make\"",
        "ls -l /opt/bin/make",
        "echo \$PATH",
        "cd ~/forward-proxy",
        "whoami",
        "make build"
        #"make run"
      ]
      connection {
          type = "ssh",
          user = "core",
          private_key = "${file(var.ssh_private_key)}"
      }
  }
}

output "forward-proxy-ip" {
  value = "${digitalocean_droplet.forward_proxy.ipv4_address}"
}
