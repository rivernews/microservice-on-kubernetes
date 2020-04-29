
# terraform doc: https://www.terraform.io/docs/providers/kubernetes/r/deployment.html
resource "kubernetes_deployment" "app" {
  metadata {
    name      = "${var.app_label}-deployment"
    namespace = kubernetes_service_account.app.metadata.0.namespace
    labels = {
      app = var.app_label
    }
  }

  spec {
    replicas = 1

    # You cannot update strategy from RollingUpdate -> Recreate
    # because strategy.rolling_update is invalid when strategy.type = Recreate
    # however, when initially is RollingUpdate, content of strategy.rolling_update
    # is stored as block on K8. To remove strategy.rolling_update, we need to set it to null (https://github.com/kubernetes/kubernetes/issues/24198)
    # However, terraform's validator will not allow us to do so, and will throw
    # error saying it requires a block. Therefore, as a workaround, we need to 
    # destroy the resource first, then create it manually in terraform
    strategy {
      // if persistent volume configured, will have to use `Recreate` type: 
      // because persistent volume requires only up to one pod present (and attach to volume) at any given time
      type = var.use_recreate_deployment_strategy || length(var.persistent_volume_mount_path_secret_name_list) > 0 ? "Recreate" : "RollingUpdate"
    }

    selector {
      match_labels = {
        app = var.app_label
      }
    }

    template {
      metadata {
        labels = {
          app = var.app_label
        }
      }

      spec {
        # This is used only when you want to set to `false`; see 
        # https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/#use-the-default-service-account-to-access-the-api-server
        # automount_service_account_token = true

        service_account_name = kubernetes_service_account.app.metadata.0.name

        image_pull_secrets {
          name = kubernetes_secret.dockerhub_secret.metadata.0.name
        }

        container {
          name  = var.app_label
          image = lower(trimspace("${var.app_container_image}:${var.app_container_image_tag}"))

          # terraform official doc: https://www.terraform.io/docs/providers/kubernetes/r/deployment.html#image_pull_policy
          # private image registry: https://stackoverflow.com/questions/49639280/kubernetes-cannot-pull-image-from-private-docker-image-repository
          image_pull_policy = "Always"

          port {
            # must specify name when having multiple ports
            name = "port-${var.app_exposed_port}"
            container_port = var.app_exposed_port
            # host_port = var.app_exposed_port
          }

          # additional exposed ports for internal traffic
          dynamic "port" {
            for_each = var.additional_exposed_ports
            content {
              name = "port-${port.key}"
              container_port = port.value
              # host_port = port.value
            }
          }

          dynamic "env" {
              for_each = var.environment_variables
              content {
                  name  = env.key
                  value = env.value
              }
          }

          # see `env_from` example at: https://www.michielsikkes.com/managing-and-deploying-app-secrets-at-firmhouse/
          env_from {
            secret_ref {
              name = kubernetes_secret.app_credentials.metadata.0.name
            }
          }

          env {
            name  = "DEPLOYED_DOMAIN"
            value = var.app_deployed_domain
          }

          env {
              name = "CORS_DOMAIN_WHITELIST"
              value = join(",", var.cors_domain_whitelist)
          }

          dynamic "resources" {
            for_each = var.memory_max_allowed != "" && var.memory_guaranteed != "" ? [true] : []
            content {
              requests {
                memory = var.memory_guaranteed
              }
              limits {
                memory = var.memory_max_allowed
              }
            }
          }

          # resources {
          #   limits {
          #     cpu    = "0.5"
          #     memory = "512Mi"
          #   }
          # requests {
          #   cpu    = "250m"
          #   memory = "50Mi"
          # }
          # }

          #   liveness_probe {
          #     http_get {
          #       path = "/nginx_status"
          #       port = 80

          #       http_header {
          #         name  = "X-Custom-Header"
          #         value = "Awesome"
          #       }
          #     }

          #     initial_delay_seconds = 3
          #     period_seconds        = 3
          #   }

          dynamic "volume_mount" {
            for_each = data.aws_ssm_parameter.persistent_volume_mount_path
            content {
              // volume_mount.key refers to array index, since `data.aws_ssm_parameter.persistent_volume_mount_path` is an array
              // volume_mount.value refers to aws ssm resource
              // in order to get the value stored in aws ssm resource, you need to second `.value`
              mount_path = volume_mount.value.value
              
              name = volume_mount.key == 0 ? "${var.app_label}-volume" : "${var.app_label}-volume-${volume_mount.key}"
            } 
          }

          # share host memory mounting at /dev/shm
          dynamic "volume_mount" {
            for_each = var.share_host_memory ? [true] : []
            content {
              # refer to the volume name
              name = "share-host-memory"
              mount_path = "/dev/shm"
            }
          }
        }
        
        # persistent volume setup
        # based on https://www.digitalocean.com/docs/kubernetes/how-to/add-volumes/
        dynamic "init_container" {
            for_each = data.aws_ssm_parameter.persistent_volume_mount_path
            content {
                name = "${var.app_label}-initial-container-${init_container.key}"
                image = "busybox"
                command = ["/bin/chmod","-R","777", init_container.value.value]
                volume_mount {
                    name = init_container.key == 0 ? "${var.app_label}-volume" : "${var.app_label}-volume-${init_container.key}"
                    mount_path = init_container.value.value
                }
            }
        }

        dynamic "volume" {
            for_each = data.aws_ssm_parameter.persistent_volume_mount_path
            content {
                name = volume.key == 0 ? "${var.app_label}-volume" : "${var.app_label}-volume-${volume.key}"
                persistent_volume_claim {
                    claim_name = kubernetes_persistent_volume_claim.app_digitalocean_pvc[volume.key].metadata.0.name
                }
            }
        }

        # share host memory mounting at /dev/shm
        # https://stackoverflow.com/a/46434614/9814131
        dynamic "volume" {
          for_each = var.share_host_memory ? [true] : []
          content {
            name = "share-host-memory"
            empty_dir {
              medium = "Memory"
            }
          }
        }

        node_selector = var.node_pool_name != "" ? {
          "doks.digitalocean.com/node-pool" = var.node_pool_name
        } : {}
      }
    }
  }
}


locals {
  app_secret_name_list = var.app_secret_name_list

  app_secret_value_list = data.aws_ssm_parameter.app_credentials.*.value

  app_secret_key_value_pairs = {
    for index, secret_name in local.app_secret_name_list : split("/", secret_name)[length(split("/", secret_name)) - 1] => local.app_secret_value_list[index]
  }
}

data "aws_ssm_parameter" "persistent_volume_mount_path" {
  count = length(var.persistent_volume_mount_path_secret_name_list)
  name = var.persistent_volume_mount_path_secret_name_list[count.index]
}

data "aws_ssm_parameter" "app_credentials" {
  count = length(local.app_secret_name_list)
  name  = local.app_secret_name_list[count.index]
}

# terraform doc: https://www.terraform.io/docs/providers/kubernetes/r/secret.html
resource "kubernetes_secret" "app_credentials" {
  metadata {
    name      = "${var.app_label}-credentials"
    namespace = kubernetes_service_account.app.metadata.0.namespace
  }
  # k8 doc: https://github.com/kubernetes/community/blob/c7151dd8dd7e487e96e5ce34c6a416bb3b037609/contributors/design-proposals/auth/secrets.md#secret-api-resource
  # default type is opaque, which represents arbitrary user-owned data.
  type = "Opaque"

  data = local.app_secret_key_value_pairs
}
