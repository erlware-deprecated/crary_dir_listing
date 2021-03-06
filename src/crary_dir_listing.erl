%%% Copyright (c) 2007, 2008 Scott Parish
%%%
%%% Permission is hereby granted, free of charge, to any
%%% person obtaining a copy of this software and associated
%%% documentation files (the "Software"), to deal in the
%%% Software without restriction, including without limitation
%%% the rights to use, copy, modify, merge, publish, distribute,
%%% sublicense, and/or sell copies of the Software, and to permit
%%% persons to whom the Software is furnished to do so, subject to
%%% the following conditions:
%%%
%%% The above copyright notice and this permission notice shall
%%% be included in all copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
%%% EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
%%% OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
%%% NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
%%% HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
%%% WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
%%% OTHER DEALINGS IN THE SOFTWARE.

%%%-------------------------------------------------------------------

%%% @author Scott Parish <srp@srparish.net>
%%% @copyright 2007, 2008 Scott Parish <srp@srparish.net>
%%% @doc This is primarily a crary handler which impliments `dir
%%% listing' functionality. Other handlers may find use of the
%%% functions here exported.

-module(crary_dir_listing).

-export([handler/2]).

%% methods other handler modules may find useful
-export([file_path/2]).
-export([write_file/2]).
-export([mime_type/1]).

-include("file.hrl").
-include("eunit.hrl").
-include("crary.hrl").
-include("uri.hrl").

-define(Kib, (1024)).
-define(Mib, (1024 * 1024)).
-define(Gib, (1024 * 1024 * 1024)).

-define(BUFSZ, 64 * ?Kib).
-define(INDEX_NAMES, ["index.html", "index.htm", "default.htm"]).

%% @doc Handle the request as any good dir lister would.
%% @spec handler(crary:crary_req(), string()) -> void()
handler(#crary_req{method = "GET"} = Req, BaseDir) ->
    case file_path(Req, BaseDir) of
        Path ->
            case file:read_file_info(Path) of
                {ok, #file_info{type = directory}} ->
                    dir_listing(Req, Path);
                {ok, #file_info{}} ->
                    write_file(Req, Path);
                {error, enoent} ->
                    crary:not_found(Req);
                {error, enotdir} ->
                    crary:not_found(Req);
                {error, eacces} ->
                    crary:forbidden(Req)
            end
    end;
handler(Req, _BaseDir) ->
    crary:not_implemented(Req).

dir_listing(Req, Path) ->
    case has_index_file(Req, Path) of
        {true, Name} ->
            write_file(Req, Path ++ "/" ++ Name);
        false ->
            case file:list_dir(Path) of
                {ok, Names} ->
                    crary:r(Req, 200, [{<<"content-type">>, <<"text/html">>}],
                            fun (W) ->
                                    write_listing(Req, W, Path, Names)
                            end);
                {error, eacces} ->
                    crary:forbidden(Req)
            end
    end.



write_listing(Req, W, Dir, Names) ->
    crary_body:write(W,
                     [<<"<!DOCTYPE HTML PUBLIC \"-//IETF//DTD HTML 4.0//EN\">
                          <html>
                           <head>
                            <title>Index of ">>, Dir, <<"</title>
                            <style type=\"text/css\">
                             td {padding-right: 14px;}
                             td.s {text-align: right;}
                             th {text-align: left;}
                             div.list { background-color: white; border-top: 1px solid #646464; border-bottom: 1px solid #646464; padding-top: 10px; padding-bottom: 14px;}
                            </style>
                           </head>

                           <body bgcolor=\"#ffffff\" text=\"#000000\">
                            <h2>Index of ">>, Dir, <<"</h2>
                            <div class=\"list\">
                             <table>
                              <thead><tr>
                               <th>Name</th><th>Last modified</th>
                               <th>Size</th><th>Type</th>
                              </tr></thead>
                              <tbody>">>]),
    lists:foreach(fun (Name) -> write_name(Req, W, Dir, Name) end, Names),
    crary_body:write(W, [<<"  </tbody>
                             </table>
                            </div>
                            <div class=\"foot\">">>, crary:ident(Req), <<"</div>
                           </body>
                          </html>">>]).


write_name(Req, W, Dir, Name) ->
    {ok, Info} = file:read_file_info(Dir ++ "/" ++ Name),
    crary_body:write(W,
                     [<<"<tr>
                          <td class=\"n\">">>,
                           format_name(Req, Name, Info),
                       <<"</td>
                          <td class=\"m\">">>, format_mtime(Info), <<"</td>
                          <td class=\"s\">">>, format_size(Info), <<"</td>
                          <td class=\"t\">">>, format_type(Name, Info), <<"</td>
                         </tr>">>]).

format_size(#file_info{size = Size}) when Size >= ?Gib ->
    io_lib:format("~.1fG", [float(Size) / ?Gib]);
format_size(#file_info{size = Size}) when Size >= ?Mib ->
    io_lib:format("~.1fM", [float(Size) / ?Mib]);
format_size(#file_info{size = Size}) ->
    io_lib:format("~.1fK", [float(Size) / ?Kib]).

format_mtime(#file_info{mtime = {{Y, M, D}, {H, Min, S}}}) ->
    io_lib:format("~.4.0w-~.2.0w-~.2.0w ~.2.0w:~.2.0w:~.2.0w",
                  [Y, M, D, H, Min, S]).

format_name(Req, Name, #file_info{type = Type}) ->
    TS = case Type of
             directory -> $/;
             _ -> ""
         end,
    [<<"<a href=\"">>,
     %% todo: use uri library to create this uri
     strip_slash((Req#crary_req.uri)#uri.raw), $/, Name, TS, <<"\">">>,
     Name, TS, <<"</a>">>].

format_type(_, #file_info{type = directory}) -> <<"Directory">>;
format_type(_, #file_info{type = device}) -> <<"Device">>;
format_type(Name, #file_info{type = regular}) ->
    mime_type(Name).

%% @doc This responder will open the file located at Path and return
%% it as the HTTP response body.
%% @spec write_file(crary:crary_req(), string()) -> void()
write_file(#crary_req{opts = Opts} = Req, Path) ->
    try
        case file:open(Path, [read, raw, binary]) of
            {ok, Fd} ->
                BufSz = proplists:get_value(
                          crary_dir_listing_buffer_size, Opts, ?BUFSZ),
                crary:r(Req, 200, [{<<"content-type">>, mime_type(Path)},
                                   {<<"content-length">>, file_len(Path)}]),
                write_file(Req, Fd, BufSz),
                crary_sock:done_writing(Req);
            {error, Reason} ->
                throw({error, Reason})
        end
    catch
        {error, enoent} ->
            crary:not_found(Req);
        {error, eacces} ->
            crary:forbidden(Req);
        {error, enotdir} ->
            crary:not_found(Req)
    end.

file_len(Path) ->
    case file:read_file_info(Path) of
        {ok, Stat} ->
            integer_to_list(Stat#file_info.size);
        {error, Reason} ->
            throw({error, Reason})
    end.

write_file(Req, Fd, BufSz) ->
    case file:read(Fd, BufSz) of
        {ok, Data} ->
            crary_sock:write(Req, Data),
            write_file(Req, Fd, BufSz);
        eof ->
            ok
    end.

has_index_file(#crary_req{opts = Opts}, Path) ->
    has_index_file(proplists:get_value(crary_dir_listing_index_file_names,
                                       Opts, ?INDEX_NAMES),
                   Path);
has_index_file([], _Path) ->
    false;
has_index_file([Name | Names], Path) ->
    case file:read_file_info(Path ++ "/" ++ Name) of
        {ok, _} ->
            {true, Name};
        {error, enoent} ->
            has_index_file(Names, Path)
    end.

%% @doc Create a file path by appending the Uri to Base (making sure
%% that Uri doesn't try to escape from Base by using `..' or such)
%% @spec file_path(crary:crary_req(), string()) -> string()
%% @throws not_found
file_path(#crary_req{uri = Uri}, Base) ->
    file_path(Uri, Base);
file_path(#uri{path = UriPath, frag = ""}, Base) ->
    file_path_(UriPath, Base);
file_path(#uri{}, _Base) ->
    throw(bad_request);
file_path(Uri, Base) when is_list(Uri) ->
    file_path(uri:from_string(Uri), Base).

file_path_(UriPath, Base)->
    Parts = lists:foldl(
              fun (Part, Acc) ->
                      case Part of
                          ".." ->
                              case Acc of
                                  [] -> throw(not_found);
                                  _ -> tl(Acc)
                              end;
                          "."  -> Acc;
                          _    -> [Part | Acc]
                      end
              end, [], string:tokens(UriPath, "/")),
    SBase = strip_slash(Base),
    case Parts of
        [] ->
            SBase;
        _ ->
            lists:flatten([SBase, $/,
                           lists:foldl(fun (Part, []) ->
                                               Part;
                                           (Part, Path) ->
                                               [Part, "/", Path]
                                       end, [], Parts)])
    end.

strip_slash(Str) ->
    string:strip(Str, right, $/).

file_path_test() ->
    ?assertMatch("/a/b/c/d", file_path("/a/b/c", "d")),
    ?assertMatch("/a/b/c/d", file_path("/a/b/c/", "d")),
    ?assertMatch("/a/b/c/d", file_path("/a/b/c/", "d/")),
    ?assertMatch("/a/b/c/d", file_path("/a/b/c/", "/d")),
    ?assertMatch("/a/b/c", file_path("/a/b/c/", "d/../")),
    ?assertMatch("/a/b/c/d2", file_path("/a/b/c/", "d/../d2")),
    ?assertMatch("/a/b/../c/d", file_path("/a/b/../c/", "d")),
    ?assertMatch("/a/b/c", file_path("/a/b/c/", "")),
    ?assertThrow(not_found, file_path("/a/b/c/", "d/../..")),
    ?assertThrow(not_found, file_path("/a/b/c/", "../..")),
    ?assertThrow(not_found, file_path("/a/b/c/", "..")),
    ?assertMatch("/a/b/c/d", file_path("/a/b/c/", "/./d")).

extension(Path) ->
    File = filename:basename(Path, []),
    case string:chr(File, $.) of
        0 -> "";
        N -> string:substr(File, N)
    end.

%% @doc Return the mime type based on the extension of the given file name.
%% @spec mime_type(string()) -> binary()
mime_type(Name) ->
    ext_mime_type(extension(Name)).

ext_mime_type(".pdf") -> <<"application/pdf">>;
ext_mime_type(".sig") -> <<"application/pgp-signature">>;
ext_mime_type(".spl") -> <<"application/futuresplash">>;
ext_mime_type(".class") -> <<"application/octet-stream">>;
ext_mime_type(".ps") -> <<"application/postscript">>;
ext_mime_type(".torrent") -> <<"application/x-bittorrent">>;
ext_mime_type(".dvi") -> <<"application/x-dvi">>;
ext_mime_type(".gz") -> <<"application/x-gzip">>;
ext_mime_type(".pac") -> <<"application/x-ns-proxy-autoconfig">>;
ext_mime_type(".swf") -> <<"application/x-shockwave-flash">>;
ext_mime_type(".tar.gz") -> <<"application/x-tgz">>;
ext_mime_type(".tgz") -> <<"application/x-tgz">>;
ext_mime_type(".tar") -> <<"application/x-tar">>;
ext_mime_type(".zip") -> <<"application/zip">>;
ext_mime_type(".mp3") -> <<"audio/mpeg">>;
ext_mime_type(".m3u") -> <<"audio/x-mpegurl">>;
ext_mime_type(".wma") -> <<"audio/x-ms-wma">>;
ext_mime_type(".wax") -> <<"audio/x-ms-wax">>;
ext_mime_type(".ogg") -> <<"application/ogg">>;
ext_mime_type(".wav") -> <<"audio/x-wav">>;
ext_mime_type(".gif") -> <<"image/gif">>;
ext_mime_type(".jpg") -> <<"image/jpeg">>;
ext_mime_type(".jpeg") -> <<"image/jpeg">>;
ext_mime_type(".png") -> <<"image/png">>;
ext_mime_type(".xbm") -> <<"image/x-xbitmap">>;
ext_mime_type(".xpm") -> <<"image/x-xpixmap">>;
ext_mime_type(".xwd") -> <<"image/x-xwindowdump">>;
ext_mime_type(".css") -> <<"text/css">>;
ext_mime_type(".html") -> <<"text/html">>;
ext_mime_type(".htm") -> <<"text/html">>;
ext_mime_type(".js") -> <<"text/javascript">>;
ext_mime_type(".asc") -> <<"text/plain">>;
ext_mime_type(".c") -> <<"text/plain">>;
ext_mime_type(".cpp") -> <<"text/plain">>;
ext_mime_type(".log") -> <<"text/plain">>;
ext_mime_type(".conf") -> <<"text/plain">>;
ext_mime_type(".text") -> <<"text/plain">>;
ext_mime_type(".txt") -> <<"text/plain">>;
ext_mime_type(".dtd") -> <<"text/xml">>;
ext_mime_type(".xml") -> <<"text/xml">>;
ext_mime_type(".mpeg") -> <<"video/mpeg">>;
ext_mime_type(".mpg") -> <<"video/mpeg">>;
ext_mime_type(".mov") -> <<"video/quicktime">>;
ext_mime_type(".qt") -> <<"video/quicktime">>;
ext_mime_type(".avi") -> <<"video/x-msvideo">>;
ext_mime_type(".asf") -> <<"video/x-ms-asf">>;
ext_mime_type(".asx") -> <<"video/x-ms-asf">>;
ext_mime_type(".wmv") -> <<"video/x-ms-wmv">>;
ext_mime_type(".bz2") -> <<"application/x-bzip">>;
ext_mime_type(".tbz") -> <<"application/x-bzip-compressed-tar">>;
ext_mime_type(".tar.bz2") -> <<"application/x-bzip-compressed-tar">>;
ext_mime_type(_) -> <<"application/octet-stream">>.

