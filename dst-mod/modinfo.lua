name = "DST MC Fusion Bridge"
description = "Local first-person building, collision and combat bridge. Requires the matching MC mod and native launcher."
author = "Jay"
version = "0.5.0"
api_version = 10
dst_compatible = true
all_clients_require_mod = false
client_only_mod = false
server_only_mod = false
configuration_options = {
    {name="connect", label="Pair with local MC test world", options={{description="Calibration only",data=false},{description="Connect",data=true}}, default=false},
}
