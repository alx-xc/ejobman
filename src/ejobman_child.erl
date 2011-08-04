%%%
%%% ejobman_child: dynamically added worker
%%% 
%%% Copyright (c) 2011 Megaplan Ltd. (Russia)
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"),
%%% to deal in the Software without restriction, including without limitation
%%% the rights to use, copy, modify, merge, publish, distribute, sublicense,
%%% and/or sell copies of the Software, and to permit persons to whom
%%% the Software is furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included
%%% in all copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
%%% EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
%%% MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
%%% IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
%%% CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
%%% TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
%%% SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
%%%
%%% @author arkdro <arkdro@gmail.com>
%%% @since 2011-07-15 10:00
%%% @license MIT
%%% @doc dynamically added worker that does the real thing.
%%%

-module(ejobman_child).
-behaviour(gen_server).

%%%----------------------------------------------------------------------------
%%% Exports
%%%----------------------------------------------------------------------------
-export([start/0, start_link/0, start_link/1, stop/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).
-export([terminate/2, code_change/3]).

%%%----------------------------------------------------------------------------
%%% Includes
%%%----------------------------------------------------------------------------

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("ejobman.hrl").
-include("amqp_client.hrl").

-define(HTTP_TIMEOUT, 15000).

%%%----------------------------------------------------------------------------
%%% gen_server callbacks
%%%----------------------------------------------------------------------------
init(Params) ->
    C = ejobman_conf:get_config_child(Params),
    mpln_p_debug:pr({?MODULE, 'init done', ?LINE, self()},
        C#child.debug, run, 1),
    {ok, C, ?TC}. % yes, this is fast and dirty hack (?TC)

%%-----------------------------------------------------------------------------
%%
%% Handling call messages
%% @since 2011-07-15 11:00
%%
-spec handle_call(any(), any(), #ejm{}) -> {stop|reply, any(), any(), any()}.

handle_call(stop, _From, St) ->
    {stop, normal, ok, St};
handle_call(status, _From, St) ->
    {reply, St, St, ?TC};
handle_call(_N, _From, St) ->
    mpln_p_debug:pr({?MODULE, 'other', ?LINE, _N, self()},
        St#child.debug, run, 4),
    New = do_smth(St),
    {reply, {error, unknown_request}, New, ?TC}.

%%-----------------------------------------------------------------------------
%%
%% Handling cast messages
%% @since 2011-07-15 11:00
%%
-spec handle_cast(any(), #ejm{}) -> any().

handle_cast(stop, St) ->
    {stop, normal, St};
handle_cast(st0p, St) ->
    St;
handle_cast(_, St) ->
    New = do_smth(St),
    {noreply, New, ?TC}.

%%-----------------------------------------------------------------------------
terminate(_, State) ->
    ejobman_handler:remove_child(self()),
    mpln_p_debug:pr({?MODULE, terminate, ?LINE, self()},
        State#child.debug, run, 2),
    ok.
%%-----------------------------------------------------------------------------
%%
%% Handling all non call/cast messages
%%
-spec handle_info(any(), #child{}) -> any().

handle_info(timeout, State) ->
    mpln_p_debug:pr({?MODULE, info_timeout, ?LINE, self()},
        State#child.debug, run, 6),
    New = do_smth(State),
    {noreply, New, ?TC};
handle_info(_Req, State) ->
    mpln_p_debug:pr({?MODULE, other, ?LINE, _Req, self()},
        State#child.debug, run, 3),
    New = do_smth(State),
    {noreply, New, ?TC}.

%%-----------------------------------------------------------------------------
code_change(_Old_vsn, State, _Extra) ->
    {ok, State}.

%%%----------------------------------------------------------------------------
%%% api
%%%----------------------------------------------------------------------------
start() ->
    start_link().
%%-----------------------------------------------------------------------------
start_link() ->
    start_link([]).
start_link(Params) ->
    gen_server:start_link(?MODULE, Params, []).
%%-----------------------------------------------------------------------------
stop() ->
    gen_server:call(?MODULE, stop).

%%%----------------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------------
%%
%% @doc processes command, then sends stop message to itself
%% @since 2011-07-15
%%
-spec do_smth(#child{}) -> #child{}.

do_smth(State) ->
    %timer:sleep(100), % FIXME: for debug only
    process_cmd(State),
    gen_server:cast(self(), stop),
    State#child{method = <<>>, url = <<>>,
        params = 'undefined', from = 'undefined'}.

%%-----------------------------------------------------------------------------
%%
%% @doc checks the command, then follows real_cmd
%% @since 2011-07-15
%%
-spec process_cmd(#child{}) -> ok.

process_cmd(#child{from = 'undefined'}) ->
    ok;
process_cmd(#child{url = <<>>}) ->
    ok;
process_cmd(#child{url = [_ | _]} = St) ->
    real_cmd(St);
process_cmd(#child{url = <<_, _/binary>> = Url_bin} = St) ->
    Url = binary_to_list(Url_bin),
    real_cmd(St#child{url = Url});
process_cmd(_) ->
    ok.
%%-----------------------------------------------------------------------------
%%
%% @doc does the command, sends reply to the client.
%% NOTE: in case of a big number of requests the TCP_WAIT problem can
%% arise. To handle that use other clients:
%% https://bitbucket.org/etc/lhttpc/wiki/Home
%% https://github.com/cmullaparthi/ibrowse
%% @since 2011-07-18
%%
real_cmd(#child{method = Method_bin, url = Url, params = Params,
        from = From} = St) ->
    mpln_p_debug:pr({?MODULE, 'real_cmd params', ?LINE, self(),
        Method_bin, Url, Params, From}, St#child.debug, run, 3),
    Method = ejobman_clean:get_method(Method_bin),
    Req = make_req(Method, Url, Params),
    Res = http:request(Method, Req,
        [{timeout, ?HTTP_TIMEOUT}, {connect_timeout, ?HTTP_TIMEOUT}],
        []),
    gen_server:reply(From, Res),
    mpln_p_debug:pr({?MODULE, 'real_cmd res', ?LINE, self(), Res},
        St#child.debug, run, 4).

%%-----------------------------------------------------------------------------
%%
%% @doc creates a http request
%% @since 2011-08-04 17:49
%%
make_req(head, Url, _Params) ->
    Hdr = [],
    {Url, Hdr};
make_req(get, Url, _Params) ->
    Hdr = [],
    {Url, Hdr};
make_req(post, Url, Params) ->
    Hdr = [],
    Ctype = "application/x-www-form-urlencoded",
    Body = make_body(Params),
    {Url, Hdr, Ctype, Body}.

%%-----------------------------------------------------------------------------
%%
%% @doc creates the body (kind of...) of a http request
%% @since 2011-08-04 17:49
%%
make_body(Pars) ->
    Text_pars = lists:map(fun make_pair/1, Pars),
    string:join(Text_pars, "&").

%%-----------------------------------------------------------------------------
%%
%% @doc makes the text pair of parameter/value
%% TODO: quoting / escaping
%%
make_pair({Par, Val}) ->
    Str = io_lib:format("~s=~s", [Par, Val]),
    lists:flatten(Str).

%%%----------------------------------------------------------------------------
%%% EUnit tests
%%%----------------------------------------------------------------------------
-ifdef(TEST).
process_cmd_test() ->
    ok = process_cmd(#child{}),
    ok = process_cmd(#child{from = 'undefined'}),
    ok = process_cmd(#child{url = <<>>}),
    ok = process_cmd(#child{url = ""}),
    ok = process_cmd([]).
-endif.
%%-----------------------------------------------------------------------------
