%%%-------------------------------------------------------------------
%%% @copyright (C) 2010-2016 2600Hz INC
%%% @doc
%%%
%%% @end
%%% @contributors
%%%   James Aimonetti
%%%-------------------------------------------------------------------
-module(kz_media_proxy).

-export([start_link/0
        ,stop/0
        ]).

-include("kazoo_media.hrl").

-spec start_link() -> startlink_ret().
start_link() ->
    kz_util:put_callid(?LOG_SYSTEM_ID),

    Dispatch = cowboy_router:compile([
                                      {'_', [{<<"/store/[...]">>, 'kz_media_store_proxy', []}
                                            ,{<<"/single/[...]">>, 'kz_media_single_proxy', []}
                                            ,{<<"/continuous/[...]">>, 'kz_media_continuous_proxy', []}
                                            ]}
                                     ]),
    maybe_start_plaintext(Dispatch),
    maybe_start_ssl(Dispatch),

    'ignore'.

-spec stop() -> 'ok'.
stop() ->
    _ = cowboy:stop_listener(?MODULE),
    _ = cowboy:stop_listener('media_mgr_ssl'),
    lager:debug("stopped kz_media_proxy listeners").

maybe_start_plaintext(Dispatch) ->
    case kapps_config:get_is_true(?CONFIG_CAT, <<"use_plaintext">>, 'true') of
        'false' -> lager:debug("plaintext media proxy support not enabled");
        'true' ->
            Port = kapps_config:get_integer(?CONFIG_CAT, <<"proxy_port">>, 24517),
            IP = get_binding_ip(),
            lager:info("trying to bind to address ~s port ~b", [inet:ntoa(IP), Port]),
            Listeners = kapps_config:get_integer(?CONFIG_CAT, <<"proxy_listeners">>, 25),

            cowboy:start_http(?MODULE
                             ,Listeners
                             ,[{'ip', IP}
                              ,{'port', Port}
                              ]
                             ,[{'env', [{'dispatch', Dispatch}]}]
                             ),
            lager:info("started media proxy on port ~p", [Port])
    end.

maybe_start_ssl(Dispatch) ->
    case kapps_config:get_is_true(?CONFIG_CAT, <<"use_ssl_proxy">>, 'false') of
        'false' -> lager:debug("ssl media proxy support not enabled");
        'true' ->
            RootDir = code:lib_dir('kazoo_media'),

            SSLCert = kapps_config:get_string(?CONFIG_CAT
                                             ,<<"ssl_cert">>
                                             ,filename:join([RootDir, <<"priv/ssl/media_mgr.crt">>])
                                             ),
            SSLKey = kapps_config:get_string(?CONFIG_CAT
                                            ,<<"ssl_key">>
                                            ,filename:join([RootDir, <<"priv/ssl/media_mgr.key">>])
                                            ),

            SSLPort = kapps_config:get_integer(?CONFIG_CAT, <<"ssl_port">>, 24518),
            SSLPassword = kapps_config:get_string(?CONFIG_CAT, <<"ssl_password">>, <<>>),

            Listeners = kapps_config:get_integer(?CONFIG_CAT, <<"proxy_listeners">>, 25),

            IP = get_binding_ip(),
            lager:info("trying to bind SSL API server to address ~s port ~b", [inet:ntoa(IP), SSLPort]),

            try
                cowboy:start_https('media_mgr_ssl', Listeners
                                  ,[{'ip', IP}
                                   ,{'port', SSLPort}
                                   ,{'certfile', find_file(SSLCert, RootDir)}
                                   ,{'keyfile', find_file(SSLKey, RootDir)}
                                   ,{'password', SSLPassword}
                                   ]
                                  ,[{'env', [{'dispatch', Dispatch}]}
                                   ,{'onrequest', fun on_request/1}
                                   ,{'onresponse', fun on_response/3}
                                   ]
                                  ),
                lager:info("started ssl media proxy on port ~p", [SSLPort])
            catch
                'throw':{'invalid_file', _File} ->
                    lager:info("SSL disabled: failed to find ~s (tried prepending ~s too)", [_File, RootDir])
            end
    end.

-spec on_request(cowboy_req:req()) -> cowboy_req:req().
on_request(Req0) ->
    {_Method, Req1} = cowboy_req:method(Req0),
    Req1.

-spec on_response(cowboy:http_status(), cowboy:http_headers(), cowboy_req:req()) -> cowboy_req:req().
on_response(_Status, _Headers, Req) -> Req.

-spec find_file(string(), string()) -> string().
find_file(File, Root) ->
    case filelib:is_file(File) of
        'true' -> File;
        'false' ->
            FromRoot = filename:join([Root, File]),
            lager:info("failed to find file at ~s, trying ~s", [File, FromRoot]),
            case filelib:is_file(FromRoot) of
                'true' -> FromRoot;
                'false' ->
                    lager:info("failed to find file at ~s", [FromRoot]),
                    throw({'invalid_file', File})
            end
    end.

-spec get_binding_ip() -> inet:ip_address().
get_binding_ip() ->
    IsIPv6Enabled = is_ip_family_supported("localhost", 'inet6'),
    IsIPv4Enabled = is_ip_family_supported("localhost", 'inet'),

    %% expilicty convert to list to allow save the default value in human readable value
    IP = kz_term:to_list(kapps_config:get_binary(?CONFIG_CAT, <<"ip">>, default_ip())),

    {'ok', DefaultIP} = inet:parse_address(kz_term:to_list(default_ip(IsIPv6Enabled))),
    {'ok', DefaultIPv4} = inet:parse_address(kz_term:to_list(default_ip('false'))),
    {'ok', DefaultIPv6} = inet:parse_address(kz_term:to_list(default_ip('true'))),

    case inet:parse_ipv6strict_address(IP) of
        {'ok', IPv6} when IsIPv6Enabled -> IPv6;
        {'ok', _} when IsIPv4Enabled ->
            lager:warning("address ~s is ipv6, but ipv6 is not supported by the system, enforcing default ipv4 ~s"
                         ,[IP, inet:ntoa(DefaultIPv4)]
                         ),
            DefaultIPv4;
        {'error', 'einval'} ->
            case inet:parse_ipv4strict_address(IP) of
                {'ok', IPv4} when IsIPv4Enabled -> IPv4;
                {'ok', _} when IsIPv6Enabled->
                    lager:warning("address ~s is ipv4, but ipv4 is not supported by the system, enforcing default ipv6 ~s"
                                 ,[IP, inet:ntoa(DefaultIPv6)]
                                 ),
                    DefaultIPv6;
                {'error', 'einval'} ->
                    lager:warning("address ~s is not a valid ipv6 or ipv4 address, enforcing default ip ~s"
                                 ,[IP, inet:ntoa(DefaultIP)]
                                 ),
                    DefaultIP
            end
    end.

-spec default_ip() -> ne_binary().
default_ip() ->
    default_ip(is_ip_family_supported("localhost", 'inet6')).

-spec default_ip(boolean()) -> ne_binary().
default_ip('true') -> <<"::">>;
default_ip('false') -> <<"0.0.0.0">>.

-spec is_ip_family_supported(string(), inet:address_family()) -> boolean().
is_ip_family_supported(Host, Family) ->
    case inet:getaddr(Host, Family) of
        {'ok', _} -> 'true';
        {'error', _} -> 'false'
    end.
