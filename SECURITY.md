# Security Policy

## Supported versions

LiveCollab is pre-1.0. Security fixes are made on the latest minor release only.

| Version | Supported |
| :--- | :--- |
| 0.5.x | Yes |
| < 0.5 | No. These versions crash on connected mount against a real `Phoenix.Presence` and contain known XSS and authorization issues (see CHANGELOG). |

## Reporting a vulnerability

Please **do not open a public issue**.

Report privately through GitHub's
[private vulnerability reporting](https://github.com/HataluliRandima/live_collab/security/advisories/new)
and include:

- the affected version(s);
- a description of the issue and its impact;
- steps or a test case to reproduce it.

You will get an acknowledgement as soon as a maintainer has triaged the report.
Fixes are released as a patch version, with a GitHub Security Advisory crediting
the reporter unless they prefer to stay anonymous.

## Scope

LiveCollab's threat model, trust boundaries and the protections it provides are
described in [guides/security.md](guides/security.md). Reports showing that a
documented protection can be bypassed are especially welcome.

Out of scope: denial of service that requires the ability to open an unlimited
number of authenticated LiveView connections (enforce connection and room limits
in your application), and issues in Phoenix, LiveView or the BEAM themselves
(report those upstream).
