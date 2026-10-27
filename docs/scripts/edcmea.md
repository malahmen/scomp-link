# Elite Dangerous market alerts — EDCMEA

`edcmea/edcmea.sh` · Engine: [malahmen/EDCMEA](https://github.com/malahmen/EDCMEA)

Listed in the launcher as `edcmea/edcmea.sh — Elite Dangerous market alerts - watch rules, email through pop, run on a schedule`.

Emails you when an Elite Dangerous station pays what you are waiting for. The
logic is the standalone **EDCMEA** engine (Python, standard library only) in its
own repository, made to run from cron; scomp-link ships the interactive
front-end and installs the schedule. The front-end finds the engine in this
order: `$EDCMEA_DIR`, a sibling `EDCMEA` checkout, `~/.cache/scomp-link/edcmea`,
and finally a clone over public HTTPS (`$EDCMEA_REPO` overrides it).

## What it does

| Menu | Engine |
| --- | --- |
| check now / dry run | `check` / `check --dry-run` - every rule once; email what is new |
| list / add / remove a rule | `rules list` / `rules add ...` / `rules remove` - add searches Ardent's commodity names first, then asks for price, pad, demand, data age, a system and a range, distance from arrival, fleet carriers |
| email | the recipient (`set email_to`), pop's settings (`pop-env`, or copied from this shell with `pop-env --import`), a test email |
| settings | `realert_increase_percent`, `cooldown_hours`, `matches_in_alert` |
| schedule | every 5-60 minutes: a systemd user timer (`edcmea-check.timer`) where systemd runs your session, a crontab line marked `# edcmea (scomp-link)` elsewhere |
| status | rules, recipient, pop, the schedule, and what each rule last alerted |

Market data comes from [Ardent Insight](https://ardent-insight.com) (the EDDN
feed, no key). Mail goes through Charm's [pop](https://github.com/charmbracelet/pop),
over Resend or SMTP; its settings live in the engine's owner-only `pop.env`,
because a cron job gets none of your shell's environment.

**What the schedule runs.** cron runs a job with `PATH=/usr/bin:/bin` and none
of your shell's variables, the systemd user manager with its own: a schedule
that relied on either would not find pop, or your rules. So the schedule is
written with everything resolved when you set it up: python3 (`$EDCMEA_PYTHON`
first) and the engine's `edcmea.py` by full path, and `EDCMEA_POP`,
`EDCMEA_CONFIG_DIR`, `EDCMEA_STATE_DIR` as the engine resolves them in this
session - in the crontab line as variables, in the unit as `Environment=`.
Every path is quoted, a space, `'`, `$` or `%` included (`\%` for cron, `%%`
for systemd). Without pop it refuses to schedule. Moved pop, Python or the
engine? Set the schedule again. The crontab line runs `check --quiet` (alerts
and errors only) into `check.log` in the state folder, so the log grows by what
happened; the timer logs to the journal. The unit has `TimeoutStartSec=15min`
behind the engine's own run deadline, and `KillMode=mixed` so a stop lets
`check` record the email it is sending. If `crontab -l` fails for any reason
but "no crontab for" you, the crontab is left alone - read as empty, the
rewrite would have dropped every line of yours.

**Secrets stay off command lines.** The SMTP password and the Resend key are
typed into a hidden field and handed to the engine on stdin; a value given as
an argument would show in every process listing while it runs.

## Tests

`tests/test-edcmea.sh`: the menus against a fake engine that records its
arguments and stdin, with recording `crontab`, `systemctl` and `uname` stubs -
rules built into flags, secrets on stdin, the crontab line replaced and removed
without touching your own lines, the systemd timer, and the guards that refuse
a schedule with no rules, no recipient or no pop, or a crontab that cannot be
read. The engine, python3 and the folders sit in paths with a space, `%`, `'`
and `$`; the crontab line is then run the way cron runs it (`%` handling, a
bare environment) and must reach python3 with the right arguments and
variables.
