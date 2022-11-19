# Authentication

## GLAuth

### Repo configuration

1. Add/Update `.vscode/extensions.json`

    ```json
    {
        "files.associations": {
            "**/cluster/**/*.sops.toml": "plaintext"
        }
    }
    ```

2. Add/Update `.gitattributes`

    ```text
    *.sops.toml linguist-language=JSON
    ```

3. Add/Update `.sops.yaml`

    ```yaml
    - path_regex: cluster/.*\.sops\.toml
        key_groups:
        - age:
            - age1hhurqwmfvl9m3vh3hk8urulfzcdsrep2ax2neazqt435yhpamu3qj20asg
    ```

## App Configuration

Below are the decrypted versions of the sops encrypted toml files.

> `passbcrypt` can be generated [on CyberChef](https://gchq.github.io/CyberChef/#recipe=Bcrypt(12)To_Hex(%27None%27,0))

1. `server.sops.toml`

    ```toml
    debug = true
    [ldap]
        enabled = true
        listen = "0.0.0.0:389"
    [ldaps]
        enabled = false
    [api]
        enabled = true
        tls = false
        listen = "0.0.0.0:5555"
    [backend]
        datastore = "config"
        baseDN = "dc=home,dc=arpa"
    ```

2. `groups.sops.toml`

    ```toml
    [[groups]]
        name = "svcaccts"
        gidnumber = 6500
    [[groups]]
        name = "admins"
        gidnumber = 6501
    [[groups]]
        name = "people"
        gidnumber = 6502
    ```

3. `users.sops.toml`

    ```toml
    [[users]]
        name = "search"
        uidnumber = 5000
        primarygroup = 6500
        passbcrypt = ""
        [[users.capabilities]]
            action = "search"
            object = "*"
    [[users]]
        name = "<name>"
        mail = ""
        givenname = "<Name>"
        sn = "<sn>"
        uidnumber = <uid>
        primarygroup = <gid>
        othergroups = [ <gid> ]
        passbcrypt = ""
    ```
