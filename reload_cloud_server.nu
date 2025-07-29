const fqdn = 'queerpri.de'
const action_interval = 2sec
use std/log

export def --env main [] {
    $env.HETZNER_API_KEY = (
        $env.HETZNER_API_KEY?
        | default {
            input --suppress-output "Enter Hetzner API Key:\n"
        }
    )
    print -e ""

    let servers = (servers_info)
    return (
        if ($servers.name has $fqdn) {
            recreate_server --server ($servers | where name == $fqdn | first)
        } else {
            create_server
        }
    )
}

def default_headers [] {
    return {Authorization: $'Bearer ($env.HETZNER_API_KEY)'}
}

def "http_get" [
    url: string,
    --headers (-H): record = {},
] {
    let headers = ($headers | merge (default_headers))
    log debug 'getting initial response'
    mut response = (
        http get -H $headers $url
    )
    if ($response.meta?.pagination? | is-empty) {
        log debug 'no pagination'
        $response = ($response | reject meta?)
        if ($response | columns | length) > 1 {
            return $response
        }
        return ($response | get ($response | columns | first))
    }
    mut result = ($response | reject meta?)
    while ($response.meta.pagination.page < $response.meta.pagination.last_page) {
        let page = $response.meta.pagination.page
        log debug $'getting page #($page + 1)'
        let updated_url = (
            $url
            | url parse
            | update params {|rec|
                return (
                    $rec.params
                    | default [[key, value]; [page, 1]]
                    | where key != 'page'
                    | append [[key, value]; [page, ($page + 1)]]
                )
            }
            | reject query
            | url join
        )
        log debug $'updated_url = ($updated_url)'
        $response = http get -H $headers $updated_url
        for key in ($response | reject meta? | columns) {
            let value = ($response | get $key)
            $result = (
                $result
                | upsert $key {|rec|
                    $rec | get $key | append $value
                }
            )
        }
    }
    if ($result | columns | length) > 1 {
        return $result
    }
    return ($result | get ($result | columns | first))
}

def await_action [] {
    mut response = $in
    while ($response.action.status == 'running') {
        sleep $action_interval
        $response = http get -H (default_headers) $'https://api.hetzner.cloud/v1/actions/($response.action.id)'
    }
    match ($response.action.status) {
        'error' => {
            return (error make {
                msg: $'error powering off server: ($response.action)',
            })
        },
        'success' => {
            return ($response)
        },
        $status => {
            return (error make {
                msg: $"unknown action status: ($status)\n($response | table -e)",
            })
        },
    }
}

def list_images [] {
    log info 'listing available images'
    return (http_get "https://api.hetzner.cloud/v1/images")
}

def servers_info [] {
    log info 'getting information on current servers'
    return (http_get "https://api.hetzner.cloud/v1/servers")
}

def create_server [] {
    log info 'creating the server'
    return (error make {
        msg: "Not yet implemented",
    })
}

def recreate_server [--server: record] {
    log info 'recreating server'

    log info 'powering off server...'
    let poweroff = (
        http post -H (default_headers) $'https://api.hetzner.cloud/v1/servers/($server.id)/actions/poweroff' ''
        | await_action
    )
    log info 'server powered off'

    let maybe_cache = (
        $server.public_net.ipv4?
        | default {
            let primary_ips = (http_get "https://api.hetzner.cloud/v1/primary_ips")
            {answer: ($primary_ips | where type == 'ipv4' and assignee_id == $server.id | first), additional: $primary_ips}
        }
    )
    let ipv4 = (
        if 'answer' in $maybe_cache {
            $maybe_cache.answer
        } else {
            $maybe_cache
        }
    )
    let ipv6 = (
        $server.public_net.ipv6?
        | default {(
            $maybe_cache.additional?
            | default { http_get "https://api.hetzner.cloud/v1/primary_ips" }
            | where type == 'ipv6' and assignee_id == $server.id
            | first
        )}
    )
    log info $"using primary ips from previous server:\nipv4: ($ipv4)\nipv6: ($ipv6)"

    log info 'disabling auto deletion of IPs, so they stick around after the server is deleted'
    for ip in [$ipv4, $ipv6] {
        http put -H (default_headers) -t application/json $'https://api.hetzner.cloud/v1/primary_ips/($ip.id)' { auto_delete: false }
    }

    log info 'unassigning ips'
    let ipv4_response = (
        http post -H (default_headers) -t application/json $'https://api.hetzner.cloud/v1/primary_ips/($ipv4.id)/actions/unassign' ''
        | await_action
    )
    let ipv6_response = (
        http post -H (default_headers) -t application/json $'https://api.hetzner.cloud/v1/primary_ips/($ipv6.id)/actions/unassign' ''
        | await_action
    )

    log info 'destroying server...'
    let server_destroy = (
        http delete -H (default_headers) $'https://api.hetzner.cloud/v1/servers/($server.id)'
        | await_action
    )
    log info 'old server destroyed'

    let ssh_key = (http_get 'https://api.hetzner.cloud/v1/ssh_keys' | first)

    let new_server = {
        name: ($server.name | default $fqdn),
        datacenter: $server.datacenter.name,
        server_type: $server.server_type.name,
        start_after_create: true,
        image: $server.image.name,
        ssh_keys: [$ssh_key.name],
        public_net: {
            ipv4: $ipv4.id,
            ipv6: $ipv6.id,
        }
        user_data: (open --raw ./cloud-init.yml | decode utf-8)
    }

    log info 'creating server...'
    let create_response = (
        http post -H (default_headers) -t application/json 'https://api.hetzner.cloud/v1/servers' $new_server
    )
    mut actions = ($create_response.next_actions | append $create_response.action)
    mut completed_actions = []
    log debug $'waiting for actions: ($actions.id | to nuon)'
    while ($actions | is-not-empty) {
        sleep $action_interval
        for action in ([] | append $actions) {
            let response = http get -H (default_headers) $'https://api.hetzner.cloud/v1/actions/($action.id)'
            match ($response.action.status) {
                'running' => {
                    log debug $'still waiting on action #($action.id)'
                },
                'error' => {
                    return (error make {
                        msg: $"error in action: ($response.action)\nactions: ($actions)\ncompleted_actions: ($completed_actions)",
                    })
                },
                'success' => {
                    log debug $'completed action #($action.id)'
                    $actions = ($actions | where id != $action.id)
                    $completed_actions = ($completed_actions | append $action)
                },
                $status => {
                    return (error make {
                        msg: $"unknown action status: ($status)\nresponse: ($response | table -e)\nactions: ($actions)\ncompleted_actions: ($completed_actions)",
                    })
                },
            }
        }
    }

    log info 'assigning PTR records to ip addresses...'
    let ipv4_ptr_response = (
        http post -H (default_headers) -t application/json $'https://api.hetzner.cloud/primary_ips/($ipv4.id)/actions/change_dns_ptr' {
            ip: $ipv4.ip,
            dns_ptr: $fqdn,
        } | await_action
    )
    let ipv6_ptr_response = (
        http post -H (default_headers) -t application/json $'https://api.hetzner.cloud/primary_ips/($ipv6.id)/actions/change_dns_ptr' {
            ip: ($ipv6.ip | str replace '::/64' '::1'),
            dns_ptr: $fqdn,
        } | await_action
    )
    log info 'finished assigning PTR records to ip addresses'
}
