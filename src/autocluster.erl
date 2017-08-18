%%==============================================================================
%% @author Gavin M. Roy <gavinr@aweber.com>
%% @copyright 2015-2016 AWeber Communications
%% @copyright 2017 Pivotal Software, Inc
%% @doc
%%
%% Startup and cluster formation uses 3 boot steps executed in order:
%%
%% 1) Acquiring a startup lock, choosing the best node to cluster with (if
%%    any) and clustering.
%% 2) Registering current node with the backend after it's ready to serve client
%%    requests.
%% 3) Releasing the startup lock. This step is executed even
%%    if an earlier phase errored  as we don't want
%%    to hold the lock forever.
%% @end
%%==============================================================================
-module(autocluster).

%% Rabbit startup entry point
-export([boot_step_discover_and_join/0,
         boot_step_register/0,
         boot_step_release_lock/0]).

-rabbit_boot_step({autocluster_discover_and_join,
                   [{description, <<"rabbitmq-autocluster: lock acquisition, discovery and clustering">>},
                    {mfa,         {autocluster, boot_step_discover_and_join, []}},
                    {enables,     pre_boot}]}).

-rabbit_boot_step({autocluster_register,
                   [{description, <<"rabbitmq-autocluster: registeration with the backend">>},
                    {mfa,         {autocluster, boot_step_register, []}},
                    {requires,    notify_cluster}]}).

-rabbit_boot_step({autocluster_unlock,
                   [{description, <<"rabbitmq-autocluster: lock release">>},
                    {mfa,        {autocluster, boot_step_release_lock, []}},
                    {requires,   autocluster_register}]}).

%% Boot sequence steps. These are exported for better diagnostics, so we can
%% get current step name using `erlang:fun_info/2`.
-export([initialize_backend/1,
         acquire_startup_lock/1,
         find_best_node_to_join/1,
         maybe_cluster/1,
         register_with_backend/1,
         release_startup_lock/1]).

-include("autocluster.hrl").

%% Export all for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.

%%--------------------------------------------------------------------
%% @doc
%% Retrieves a list of registered nodes from the  backend, chooses
%% the best one (if any at all) and tries to join that node.
%% Startup sequence is protected against races during initial cluster formation via a locking
%% mechanism (or by randomized startup delay for backends hat do not support locking).
%% @end
%%--------------------------------------------------------------------
-spec boot_step_discover_and_join() -> ok.
boot_step_discover_and_join() ->
    ensure_logging_configured(),
    autocluster_log:info("Running discover/join step"),
    start_dependee_applications(),
    Steps = [fun autocluster:initialize_backend/1,
             fun autocluster:acquire_startup_lock/1,
             fun autocluster:find_best_node_to_join/1,
             fun autocluster:maybe_cluster/1],
    State = new_startup_state(),
    with_stopped_app(fun() -> run_steps(Steps, State) end),
    ok.

%%--------------------------------------------------------------------
%% @doc
%% At this point we are ready to serve client requests, so it's a good time to
%% register ourselves with the backend.
%%
%% TODO: how should it work when we failed to join to the cluster
%% but the failure mode is `ignore`? Currently it tries to register this
%% node even in a case of an error, but maybe we should skip
%% registration step instead?
%%
%% @end
%%--------------------------------------------------------------------
boot_step_register() ->
    autocluster_log:info("Running registeration step"),
    run_steps([fun autocluster:register_with_backend/1]).

%%--------------------------------------------------------------------
%% @doc
%% Startup sequence finished, release the lock to let other nodes to proceed.
%% @end
%%--------------------------------------------------------------------
boot_step_release_lock() ->
    autocluster_log:info("Running lock release step"),
    run_steps([fun autocluster:release_startup_lock/1]).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Run initializations steps in order.
%%
%% When a step succeeds, it returns updated state that is passed on to
%% the subsequent steps.
%%
%% When a step fails, an error is logged and sequence processing is
%% halted. Depending on the failure mode run_steps/1 can return `ok`
%% or terminate with `exit({error, Reason})`. Returing and throwing
%% `{error, Reason}` have the same effect, as RabbitMQ boot steps will
%% convert an error return to an exit.  Throwing in this code avoids
%% explicit error handling.
%%
%% Initial and final states are stored in the app environment (managed by
%% set_run_steps_state/1). This way we can split the startup sequence
%% into different steps that share some state.
%% @end
%% --------------------------------------------------------------------
-spec run_steps([StepFun]) -> ok when
      StepFun :: fun((#startup_state{}) -> {ok, #startup_state{}} | {error, string()}).
run_steps([]) ->
    ok;
run_steps([Step|Rest]) ->
    {_, StepName} = erlang:fun_info(Step, name),
    autocluster_log:info("Running step ~p", [StepName]),
    State = get_run_steps_state(),
    StopOnError = failure_mode() =:= stop,
    case Step(State) of
        {error, unconfigured} ->
            autocluster_log:warning("Skipping step ~s because backend module is not configured! ",
                [StepName]),
            ok;
        {error, Reason} when StopOnError =:= false ->
            autocluster_log:error("Step ~s failed, will conitnue nevertheless. Failure reason: ~s.",
                                  [StepName, Reason]),
            ok;
        {error, Reason} when StopOnError =:= true ->
            autocluster_log:error("Step ~s failed, halting startup. Failure reason: ~s.",
                                  [StepName, Reason]),
            exit({error, Reason});
        {ok, NewState} ->
            set_run_steps_state(NewState),
            run_steps(Rest)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Shortcut for run_steps/1 with explicitly passed state.
%% @end
%%--------------------------------------------------------------------
run_steps(Steps, InitialState) ->
    set_run_steps_state(InitialState),
    run_steps(Steps).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Stores some state for later reuse by run_steps/1.
%% @end
%%--------------------------------------------------------------------
set_run_steps_state(State) ->
    application:set_env(autocluster, startup_steps_state, State).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Retrieves state stored by set_run_steps_state/1.
%% @end
%%--------------------------------------------------------------------
get_run_steps_state() ->
    {ok, State} = application:get_env(autocluster, startup_steps_state),
    State.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Boot steps
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Step 1: Ensure that a valid backend is chosen and pass information
%% about it to the next step(s).
%% @end
%%--------------------------------------------------------------------
-spec initialize_backend(#startup_state{}) -> {ok, #startup_state{}} | {error, iolist()}.
initialize_backend(State) ->
  ok = maybe_configure_proxy(),
  case detect_backend(autocluster_config:get(backend)) of
    {ok, Name, Mod} ->
      {ok, State#startup_state{backend_name = Name, backend_module = Mod}};
    {ok, Name, Mod, RequiredApps} ->
      autocluster_log:info("Starting dependencies of backend ~s: ~p", [Name, RequiredApps]),
      _ = [ application:ensure_all_started(App) || App <- RequiredApps],
      {ok, State#startup_state{backend_name = Name, backend_module = Mod}};
    {error, Error} ->
      {error, Error}
  end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Step 2: Acquire a startup lock in the backend to minimise startup
%% races when a new cluster if formed. If the backend doesn't implement locking,
%% fall back to randomized startup delay.
%% @end
%%--------------------------------------------------------------------
-spec acquire_startup_lock(#startup_state{}) -> {ok, #startup_state{}} | {error, string()}.
acquire_startup_lock(State) ->
    case backend_lock(State) of
        {ok, LockData} ->
            autocluster_log:info("Startup lock acquired", []),
            {ok, State#startup_state{startup_lock_data = LockData}};
        ok ->
            autocluster_log:info("Startup lock acquired", []),
            {ok, State};
        not_supported ->
            maybe_delay_startup(),
            {ok, State};
        {error, unconfigured} ->
            {error, unconfigured};
        {error, Reason} ->
            {error, lists:flatten(io_lib:format("Failed to acquire startup lock: ~s", [Reason]))}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Step 3: Fetch a list of currently registered nodes from the backend, collect
%% additional information about those nodes (reachability, uptime, cluster
%% size). Choose a preferred node: a running and reachable node that is clustered with the
%% majority of other running nodes, with longest uptime. Inability to find
%% a live node to join to is not considered to be an error, just means that no
%% clustering is needed.
%% @end
%%--------------------------------------------------------------------
-spec find_best_node_to_join(#startup_state{}) -> {ok, #startup_state{}} | {error, string()}.
find_best_node_to_join(State) ->
    case backend_nodelist(State) of
        {ok, Nodes} ->
            autocluster_log:info("List of registered nodes retrieved from the backend: ~p", [Nodes]),
            BestNode = choose_best_node(autocluster_util:augment_nodelist(Nodes)),
            autocluster_log:info("Picked node as the preferred choice for joining: ~p", [BestNode]),
            {ok, State#startup_state{best_node_to_join = BestNode}};
        {error, Reason} ->
            {error, lists:flatten(io_lib:format("Failed to fetch list of nodes from the backend: ~p", [Reason]))}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Step 4: Current node joins the cluster if we have a preferred node
%% to join to and aren't member of the cluster already. Otherwise
%% a no-op.
%%
%% There are 3 possible situations here (that roughly correspond to
%% the case statements in `rabbit_mnesia:join_cluster/2`):
%%
%% 1) Discovery node thinks that we are not clustered with
%%    it. `rabbit_mnesia:join_cluster/2` resets the node on current node
%%    and joins it to the cluster.
%%
%% 2) Discovery node thinks that we are clustered with it, and so do we.
%%    We continue startup as usual, but startup may fail if
%%    databases have diverged. Resetting will not help in this
%%    case, because discovery node will not forget about us during
%%    reset. But when automatic or manual cleanup will finally kick
%%    out this node from the rest of the cluster, this will be handled
%%    as the first situation (during next startup attempt).
%%
%% 3) Discovery node thinks that we are clustered with it, but we
%%    don't (this node was reset).  Resetting mnesia will not
%%    make things better, we can only wait for cleanup; after that
%%    we transition to the first case above.
%%
%% This is the reasoning behind why this plugin shouldn't perform
%% explicit node reset.
%%
%% @end
%%--------------------------------------------------------------------
-spec maybe_cluster(#startup_state{}) -> {ok, #startup_state{}} | {error, string()}.
maybe_cluster(#startup_state{best_node_to_join = undefined} = State) ->
    autocluster_log:info("We are the first node in the cluster, starting up unconditionally."),
    {ok, State};
maybe_cluster(#startup_state{best_node_to_join = DNode} = State) ->
    Result =
        case ensure_clustered_with(DNode) of
            ok ->
                {ok, State};
            {error, Reason} ->
                {error, io_lib:format("Failed to cluster with ~s: ~s", [DNode, Reason])}
        end,
    Result.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Step 5: Registers node in a choosen backend. For backends that
%% require some health checker/TTL updater, it also starts those processes.
%% @end
%%--------------------------------------------------------------------
-spec register_with_backend(#startup_state{}) -> {ok, #startup_state{}} | {error, iolist()}.
register_with_backend(State) ->
    case backend_register(State) of
        ok ->
            {ok, State};
        {error, unconfigured} ->
            {error, unconfigured};
        {error, Reason} ->
            {error, io_lib:format("Failed to register in backend: ~s", [Reason])}

    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Step 6: Tries to release previously acquired startup lock. Failure to release the lock
%% is considered an error.
%% @end
%%--------------------------------------------------------------------
-spec release_startup_lock(#startup_state{}) -> {ok, #startup_state{}} | {error, iolist()}.
release_startup_lock(State) ->
    case backend_unlock(State) of
        ok ->
            {ok, State};
        {error, unconfigured} ->
            {error, unconfigured};
        {error, Reason} ->
            {error, io_lib:format("Failed to release startup lock: ~s", [Reason])}
    end.

%%
%% Failure Handling
%%

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Returns the configured failure mode. Unknown mode
%% values are treated as `ignore`.
%% @end
%%--------------------------------------------------------------------
-spec failure_mode() -> stop | ignore.
failure_mode() ->
    case autocluster_config:get(autocluster_failure) of
        stop -> stop;
        ignore -> ignore;
        BadMode ->
            autocluster_log:error("Invalid startup failure mode ~p, using 'ignore'~n", [BadMode]),
            ignore
    end.

%%
%% Randomized Startup Delay
%%

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Get the configuration for the maximum startup delay in seconds and
%% then sleep a random amount.
%% @end
%%--------------------------------------------------------------------
-spec maybe_delay_startup() -> ok.
maybe_delay_startup() ->
  startup_delay(autocluster_config:get(startup_delay) * 1000).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Sleep a random number of seconds determined between 0 and the
%% maximum value specified.
%% @end
%%--------------------------------------------------------------------
-spec startup_delay(integer()) -> ok.
startup_delay(0) -> ok;
startup_delay(Max) ->
  Duration = rabbit_misc:random(Max),
  autocluster_log:info("Delaying startup for ~pms.", [Duration]),
  timer:sleep(Duration).


%%
%% Backend helpers: these forward requests to the backend module stored in
%% #startup_state{}.
%%

-spec backend_register(#startup_state{}) -> ok | {error, iolist()}.
backend_register(#startup_state{backend_module = unconfigured}) ->
    {error, unconfigured};
backend_register(#startup_state{backend_module = Mod}) ->
    Mod:register().

-spec backend_unlock(#startup_state{}) -> ok | {error, iolist()}.
backend_unlock(#startup_state{backend_module = unconfigured}) ->
    {error, unconfigured};
backend_unlock(#startup_state{backend_module = Mod, startup_lock_data = Data}) ->
    Mod:unlock(Data).


-spec backend_lock(#startup_state{}) -> ok | {ok, LockData :: term()} | not_supported | {error, iolist()}.
backend_lock(#startup_state{backend_module = unconfigured}) ->
    {error, unconfigured};
backend_lock(#startup_state{backend_module = Module}) ->
    Module:lock(atom_to_list(node())).



-spec backend_nodelist(#startup_state{}) -> {ok, [node()]} | {error, iolist()}.
backend_nodelist(#startup_state{backend_module = unconfigured}) ->
    {error, unconfigured};
backend_nodelist(#startup_state{backend_module = Module}) ->
    Module:nodelist().

%%
%% Misc
%%

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Configure autocluster logging at the configured level, if it's not
%% already configured at the same level.
%% @end
%%--------------------------------------------------------------------
-spec ensure_logging_configured() -> ok.
ensure_logging_configured() ->
  Level = autocluster_config:get(autocluster_log_level),
  autocluster_log:set_level(Level).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Start all OTP applications that can be required by backend modules.
%% @end
%%--------------------------------------------------------------------
-spec start_dependee_applications() -> ok.
start_dependee_applications() ->
    %% XXX Not all backends need this
    {ok, _} = application:ensure_all_started(inets),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc Currently chooses first alive node from a list sorted by node name.
%% XXX Take into account other considerations: uptime, size of the
%% cluster and so on.
%% @end
%%--------------------------------------------------------------------
-spec choose_best_node([#candidate_seed_node{}]) -> node() | undefined.
choose_best_node([_|_] = NonEmptyNodeList) ->
    autocluster_log:debug("Asked to choose preferred node from the list of: ~p", [NonEmptyNodeList]),
    Sorted = lists:sort(fun(#candidate_seed_node{name = A}, #candidate_seed_node{name = B}) ->
                                A < B
                        end,
                        NonEmptyNodeList),
    WithoutSelfAndDead = lists:filter(fun (#candidate_seed_node{name = Node}) when Node =:= node() -> false;
                                          (#candidate_seed_node{alive = false}) -> false;
                                          (_) -> true
                                      end, Sorted),
    autocluster_log:debug("Filtered node list (does not include us and non-running/reachable nodes): ~p", [WithoutSelfAndDead]),
    case WithoutSelfAndDead of
        [BestNode|_] ->
            BestNode#candidate_seed_node.name;
        _ ->
            undefined
    end;
choose_best_node([]) ->
    autocluster_log:warning("No nodes to choose the preferred from!"),
    undefined;
choose_best_node(Other) ->
    autocluster_log:debug("choose_best_node invoked with an unexpected value: ~p", [Other]),
    undefined.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Converts backend specified in configuration into its proper
%% internal name and module name.
%% @end
%%--------------------------------------------------------------------
-spec detect_backend(atom()) -> Backend | BackendWithDeps | {error, iolist()} when
    Backend :: {ok, atom(), module()},
    BackendWithDeps :: {ok, atom(), module(), [atom()]}.
detect_backend(aws) ->
  autocluster_log:debug("Using AWS backend"),
  {ok, aws, autocluster_aws, [rabbitmq_aws]};

detect_backend(consul) ->
  autocluster_log:debug("Using consul backend"),
  {ok, consul, autocluster_consul};

detect_backend(dns) ->
  autocluster_log:debug("Using DNS backend"),
  {ok, dns, autocluster_dns};

detect_backend(etcd) ->
  autocluster_log:debug("Using etcd backend"),
  {ok, etcd, autocluster_etcd};

detect_backend(k8s) ->
  autocluster_log:debug("Using k8s backend"),
  {ok, k8s, autocluster_k8s};

detect_backend(unconfigured) ->
  {error, unconfigured};

detect_backend(Backend) ->
  {error, io_lib:format("Unsupported backend: ~s.", [Backend])}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Tries to join current node to given node (unless we are already
%% clustered with that discovery node). rabbit_mnesia:join_cluster/2
%% is idempotent in recent rabbitmq releases, and contains some clever
%% checks. So we are just going to call it unconditionally.
%%
%% @end
%%--------------------------------------------------------------------
-spec ensure_clustered_with(node()) -> ok | {error, iolist()}.
ensure_clustered_with(Target) ->
    case rabbit_mnesia:join_cluster(Target, autocluster_config:get(node_type)) of
        ok ->
            ok;
        {ok, already_member} ->
            ok;
        {error, Reason} ->
            {error, lists:flatten(io_lib:format("~w", [Reason]))}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Stops 'rabbit' and 'mnesia' applications.
%% @end
%%--------------------------------------------------------------------
-spec ensure_app_stopped() -> ok.
ensure_app_stopped() ->
    _ = application:stop(rabbit), %% rabbit:stop/0 will hang at that point
    _ = mnesia:stop(),
    autocluster_log:info("Apps 'rabbit' and 'mnesia' successfully stopped"),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Starts 'rabbit' and 'mnesia' applications.
%% @end
%%--------------------------------------------------------------------
-spec ensure_app_running() -> ok.
ensure_app_running() ->
    ok = mnesia:start(),
    rabbit:start(),
    autocluster_log:info("Starting back 'rabbit' application"),
    ok.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Returns new empty startup state.
%% @end
%%--------------------------------------------------------------------
-spec new_startup_state() -> #startup_state{}.
new_startup_state() ->
    #startup_state{backend_name = unconfigured
                  ,backend_module = unconfigured
                  ,best_node_to_join = undefined
                  ,startup_lock_data = undefined
                  }.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Runs given function with stopped rabit/mnesia apps. Starts them
%% back after the function returns.
%% @end
%%--------------------------------------------------------------------
with_stopped_app(Fun) ->
    ensure_app_stopped(),
    Fun(),
    ensure_app_running().

%%--------------------------------------------------------------------
%% @private
%% @doc Configure http proxy options if specified in configuration.
%% @end
%%--------------------------------------------------------------------
-spec maybe_configure_proxy() -> ok.
maybe_configure_proxy() ->
  NoProxy = autocluster_config:get(no_proxy),
  ok = maybe_set_proxy(proxy, autocluster_config:get(http_proxy), NoProxy),
  ok = maybe_set_proxy(https_proxy, autocluster_config:get(https_proxy), NoProxy),
  ok.

%%--------------------------------------------------------------------
%% @private
%% @doc Set httpc proxy options.
%% @end
%%--------------------------------------------------------------------
-spec maybe_set_proxy(Option :: atom(),
                      ProxyUrl :: string(),
                      NoProxy :: string()) -> ok | {error, Reason :: term()}.
maybe_set_proxy(_Option, "undefined", _NoProxy) -> ok;
maybe_set_proxy(Option, ProxyUrl, NoProxy) ->
  case parse_proxy_uri(Option, ProxyUrl) of
    {ok, {_Scheme, _UserInfo, Host, Port, _Path, _Query}} ->
      autocluster_log:debug(
        "Configuring ~s: ~p, no_proxy: ~p", [Option, {Host, Port}, get_no_proxy(NoProxy)]),
      httpc:set_options([{Option, {{Host, Port}, get_no_proxy(NoProxy)}}]);
    {error, Reason} -> {error, Reason}
  end.

%%--------------------------------------------------------------------
%% @private
%% @doc Create list of no_proxy hosts in comma separated list string.
%% @end
%%--------------------------------------------------------------------
-spec get_no_proxy(NoProxy :: string()) -> list().
get_no_proxy("undefined") -> [];
get_no_proxy(NoProxy) ->
  [string:strip(S) || S <- string:tokens(NoProxy, ",")].

%%--------------------------------------------------------------------
%% @private
%% @doc Support defining proxy address with or without uri scheme.
%% @end
%%--------------------------------------------------------------------
-spec parse_proxy_uri(ProxyType :: atom(), ProxyUrl :: string()) -> tuple().
parse_proxy_uri(ProxyType, ProxyUrl) ->
  case http_uri:parse(ProxyUrl) of
    {ok, Result} -> {ok, Result};
    {error, _} ->
      case ProxyType of
        proxy -> http_uri:parse("http://" ++ ProxyUrl);
        https_proxy -> http_uri:parse("https://" ++ ProxyUrl)
      end
  end.
