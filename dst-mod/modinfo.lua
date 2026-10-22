name = "DST MC First Person Gate"
description = "Local test-world camera and graphics gate. Requires the dedicated native launcher."
author = "Jay"
version = "0.4.0"
api_version = 10
dst_compatible = true
all_clients_require_mod = false
client_only_mod = false
server_only_mod = false
configuration_options = {
    {name="connect", label="Pair with local MC test world", options={{description="Calibration only",data=false},{description="Connect",data=true}}, default=false},
}
