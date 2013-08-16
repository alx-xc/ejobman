-ifndef(ejobman_chi).
-define(ejobman_chi, true).

-record(chi, {
    pid,
    id,
    mon,
    os_pid,
    tag,
    alive=true,
    payload,
    stop={0,0,0}, % time of marking dead
    start={0,0,0} % time in now() format
}).

-endif.
