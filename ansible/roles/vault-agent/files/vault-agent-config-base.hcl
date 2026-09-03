pid_file = "./pidfile"

vault {
  address = "https://vault.home:8200"
  tls_skip_verify = false
}

auto_auth {
  method {
    type      = "approle"

    config = {
      role_id_file_path = "/etc/vault-agent.d/roleid"
      secret_id_file_path = "/etc/vault-agent.d/secretid"
      remove_secret_id_file_after_reading = false
    }
  }

  sink {
    type = "file"
    config = {
      #path = "/etc/vault-agent.d/sink.txt"
      path = "/tmp/vault-agent-sink.txt"
    }
  }
}

# Vault Agent template blocks are managed below
