%%%-------------------------------------------------------------------
%%% @author Paolo D'Incau <paolo.dincau@gmail.com>
%%% @copyright (C) 2013, Paolo D'Incau
%%% @doc
%%%
%%% @end
%%% Created : 18 Apr 2013 by Paolo D'Incau <paolo.dincau@gmail.com>
%%%-------------------------------------------------------------------
-module(gcm).

-behaviour(gen_server).

%% API
-export([start/2, start/3, stop/1, start_link/2, start_link/3]).
-export([push/3, sync_push/3, update_error_fun/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-define(BASEURL, "https://android.googleapis.com/gcm/send").

-record(state, {key, retry_after, error_fun}).

%%%===================================================================
%%% API
%%%===================================================================
start(Name, Key) ->
    start(Name, Key, fun handle_error/2).

start(Name, Key, ErrorFun) ->
    gcm_sup:start_child(Name, Key, ErrorFun).

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(Name, Key) ->
    start_link(Name, Key, fun handle_error/2).

start_link(Name, Key, ErrorFun) ->
    gen_server:start_link({local, Name}, ?MODULE, [Key, ErrorFun], []).

stop(Name) ->
    gen_server:call(Name, stop).

push(Name, RegIds, Message) ->
    gen_server:cast(Name, {send, RegIds, Message}).

sync_push(Name, RegIds, Message) ->
    gen_server:call(Name, {send, RegIds, Message}).

update_error_fun(Name, Fun) ->
    gen_server:cast(Name, {error_fun, Fun}).
%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([Key, ErrorFun]) ->
    {ok, #state{key=Key, retry_after=0, error_fun=ErrorFun}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(stop, _From, State) ->
    {stop, normal, stopped, State};

handle_call({send, RegIds, Message}, _From, #state{key=Key} = State) ->
    {reply, do_push(RegIds, Message, Key, undefined), State};

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast({send, RegIds, Message}, #state{key=Key, error_fun=ErrorFun} = State) ->
    do_push(RegIds, Message, Key, ErrorFun),
    {noreply, State};

handle_cast({error_fun, Fun}, State) ->
    NewState = State#state{error_fun=Fun},
    {noreply, NewState};

handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
do_push(RegIds, Message, Key, ErrorFun) ->
    error_logger:info_msg("Message=~p; RegIds=~p~n", [Message, RegIds]),
    Request = jsx:encode([{<<"registration_ids">>, RegIds}|Message]),
    ApiKey = string:concat("key=", Key),
    
    try httpc:request(post, {?BASEURL, [{"Authorization", ApiKey}], "application/json", Request}, [], []) of
        {ok, {{_, 200, _}, _Headers, Body}} ->
            Json = jsx:decode(response_to_binary(Body)),
            handle_push_result(Json, RegIds, ErrorFun);
        {error, Reason} ->
	    error_logger:error_msg("Error in request. Reason was: ~p~n", [Reason]),
            {error, Reason};
        {ok, {{_, 400, _}, _, _}} ->
	    error_logger:error_msg("Error in request. Reason was: json_error~n", []),
            {error, json_error};
        {ok, {{_, 401, _}, _, _}} ->
	    error_logger:error_msg("Error in request. Reason was: authorization error~n", []),
            {error, auth_error};
        {ok, {{_, Code, _}, Headers, _}} when Code >= 500 andalso Code =< 599 ->
	    RetryTime = headers_parser:retry_after_from(Headers),
	    error_logger:error_msg("Error in request. Reason was: retry. Will retry in: ~p~n", [RetryTime]),
	    do_backoff(RetryTime, RegIds, Message, Key, ErrorFun) ,
            {error, retry};
        {ok, {{_StatusLine, _, _}, _, _Body}} ->
	    error_logger:error_msg("Error in request. Reason was: timeout~n", []),
            {error, timeout};
        OtherError ->
	    error_logger:error_msg("Error in request. Reason was: ~p~n", [OtherError]),
            {noreply, unknown}
    catch
        Exception ->
	    error_logger:error_msg("Error in request. Exception ~p while calling URL: ~p~n", [Exception, ?BASEURL]),
            {error, Exception}
    end.


handle_push_result(Json, RegIds, undefined) ->
    {_Multicast, _Success, _Failure, _Canonical, Results} = get_response_fields(Json),
    lists:map(fun({Result, RegId}) -> 
		      parse_result(Result, RegId, fun(E, I) -> {E, I} end) 
	      end, lists:zip(Results, RegIds));

handle_push_result(Json, RegIds, ErrorFun) ->
    {_Multicast, _Success, Failure, Canonical, Results} = get_response_fields(Json),
    case to_be_parsed(Failure, Canonical) of
        true ->
            lists:foreach(fun({Result, RegId}) -> parse_result(Result, RegId, ErrorFun) end,
			  lists:zip(Results, RegIds));
        false ->
            ok
    end.

response_to_binary(Json) when is_binary(Json) ->
    Json;

response_to_binary(Json) when is_list(Json) ->
    list_to_binary(Json).

get_response_fields(Json) ->
    {
      proplists:get_value(<<"multicast_id">>, Json),
      proplists:get_value(<<"success">>, Json),
      proplists:get_value(<<"failure">>, Json),
      proplists:get_value(<<"canonical_ids">>, Json),
      proplists:get_value(<<"results">>, Json)
    }.

to_be_parsed(0, 0) -> false;

to_be_parsed(_Failure, _Canonical) -> true.

parse_result(Result, RegId, ErrorFun) ->
    case {
      proplists:get_value(<<"error">>, Result),
      proplists:get_value(<<"message_id">>, Result),
      proplists:get_value(<<"registration_id">>, Result)
     } of
        {Error, undefined, undefined} when Error =/= undefined ->
            ErrorFun(Error, RegId);
        {undefined, MessageId, undefined} when MessageId =/= undefined ->
            ok;
        {undefined, MessageId, NewRegId} when MessageId =/= undefined andalso NewRegId =/= undefined ->
            ErrorFun(<<"NewRegistrationId">>, {RegId, NewRegId})
    end.

handle_error(<<"NewRegistrationId">>, {RegId, NewRegId}) ->
    error_logger:info_msg("Message sent. Update id ~p with new id ~p.~n", [RegId, NewRegId]),
    ok;

handle_error(<<"Unavailable">>, RegId) ->
    %% The server couldn't process the request in time. Retry later with exponential backoff.
    error_logger:error_msg("unavailable ~p~n", [RegId]),
    ok;

handle_error(<<"InternalServerError">>, RegId) ->
    % GCM had an internal server error. Retry later with exponential backoff.
    error_logger:error_msg("internal server error ~p~n", [RegId]),
    ok;

handle_error(<<"InvalidRegistration">>, RegId) ->
    %% Invalid registration id in database.
    lager:error("invalid registration ~p~n", [RegId]),
    ok;

handle_error(<<"NotRegistered">>, RegId) ->
    %% Application removed. Delete device from database.
    error_logger:error_msg("not registered ~p~n", [RegId]),
    ok;

handle_error(UnexpectedError, RegId) ->
    %% There was an unexpected error that couldn't be identified.
    error_logger:error_msg("unexpected error ~p in ~p~n", [UnexpectedError, RegId]),
    ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Other possible errors:					%%
%%	<<"InvalidPackageName">>				%%
%%      <<"MissingRegistration">>				%%
%%	<<"MismatchSenderId">>					%%
%%	<<"MessageTooBig">>					%%
%%      <<"InvalidDataKey">>					%%
%%	<<"InvalidTtl">>					%%
%%								%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

do_backoff(RetryTime, RegIds, Message, Key, ErrorFun) ->
    case RetryTime of
	{ok, Time} ->
	    timer:apply_after(Time * 1000, ?MODULE, do_push, [RegIds, Message, Key, ErrorFun]);
	no_retry ->
	    ok
    end.
