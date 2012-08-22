%% @doc The coordinator for stat get operations.  The key here is to
%% generate the preflist just like in wrtie_fsm and then query each
%% replica and wait until a quorum is met.
-module(snarl_group_read_fsm).
-behavior(gen_fsm).
-include("snarl.hrl").

%% API
-export([start_link/4, get/1, list/0]).

%% Callbacks
-export([init/1, code_change/4, handle_event/3, handle_info/3,
         handle_sync_event/4, terminate/3]).

%% States
-export([prepare/2, execute/2, waiting/2]).

-record(state, {req_id,
                from,
		group,
		op,
                preflist,
                num_r=0,
                replies=[]}).

%%%===================================================================
%%% API
%%%===================================================================

start_link(Op, ReqID, From, Group) ->
    gen_fsm:start_link(?MODULE, [Op, ReqID, From, Group], []).

get(Group) ->
    ?PRINT({get, Group}),
    ReqID = mk_reqid(),
    snarl_group_read_fsm_sup:start_read_fsm([get, ReqID, self(), Group]),
    {ok, ReqID}.

list() ->
    ReqID = mk_reqid(),
    snarl_group_read_fsm_sup:start_read_fsm([list, ReqID, self(), undefined]),
    {ok, ReqID}.


%%%===================================================================
%%% States
%%%===================================================================

%% Intiailize state data.
init([Op, ReqId, From, Group]) ->
    ?PRINT({init, [Op, ReqId, From, Group]}),
    SD = #state{req_id=ReqId,
                from=From,
		op=Op,
                group=Group},
    {ok, prepare, SD, 0};

init([Op, ReqId, From]) ->
    ?PRINT({init, [Op, ReqId, From]}),
    SD = #state{req_id=ReqId,
                from=From,
		op=Op},
    {ok, prepare, SD, 0}.

%% @doc Calculate the Preflist.
prepare(timeout, SD0=#state{group=Group}) ->
    ?PRINT({prepare, Group}),
    DocIdx = riak_core_util:chash_key({<<"group">>, term_to_binary(Group)}),
    Prelist = riak_core_apl:get_apl(DocIdx, ?N, snarl_group),
    SD = SD0#state{preflist=Prelist},
    {next_state, execute, SD, 0}.

%% @doc Execute the get reqs.
execute(timeout, SD0=#state{req_id=ReqId,
                            group=Group,
			    op=Op,
                            preflist=Prelist}) ->
    ?PRINT({execute, Group}),
    case Group of
	undefined ->
	    snarl_group_vnode:Op(Prelist, ReqId);
	_ ->
	    snarl_group_vnode:Op(Prelist, ReqId, Group)
    end,
    {next_state, waiting, SD0}.

%% @doc Wait for R replies and then respond to From (original client
%% that called `rts:get/2').
%% TODO: read repair...or another blog post?
waiting({ok, ReqID, Val}, SD0=#state{from=From, num_r=NumR0, replies=Replies0}) ->
    ?PRINT({waiting, ReqID, Val}),
    NumR = NumR0 + 1,
    Replies = [Val|Replies0],
    SD = SD0#state{num_r=NumR,replies=Replies},
    if
        NumR =:= ?R ->
            Reply =
                case lists:any(different(Val), Replies) of
                    true ->
                        Replies;
                    false ->
                        Val
                end,
            From ! {ReqID, ok, Reply},
            {stop, normal, SD};
        true -> {next_state, waiting, SD}
    end.

handle_info(_Info, _StateName, StateData) ->
    {stop,badmsg,StateData}.

handle_event(_Event, _StateName, StateData) ->
    {stop,badmsg,StateData}.

handle_sync_event(_Event, _From, _StateName, StateData) ->
    {stop,badmsg,StateData}.

code_change(_OldVsn, StateName, State, _Extra) -> {ok, StateName, State}.

terminate(_Reason, _SN, _SD) ->
    ok.

%%%===================================================================
%%% Internal Functions
%%%===================================================================

different(A) -> fun(B) -> A =/= B end.

mk_reqid() -> erlang:phash2(erlang:now()).