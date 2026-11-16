# Security Policy

## Supported Versions

Security fixes go into the latest release only. Please check that the problem
still happens on it before reporting.

## Reporting a Vulnerability

Please do not open a public issue for a security problem. Report it privately
through GitHub's
[private vulnerability reporting](https://github.com/NobleDoodle/omarchroma/security/advisories/new)
instead. Only you and the maintainer can see the report.

Please include:

- What the issue is and what an attacker could do with it.
- Steps or a proof of concept to reproduce it.
- The Omarchroma version (the `VERSION` file in the plugin folder, or
  `pacman -Q hyprchroma`) and your Omarchy version.

Replies come on the report itself. Once a fix is released, the advisory is
published and you are credited, unless you would rather not be.

## Scope

Omarchroma runs with your user's permissions: the bar widget inside
`omarchy-shell`, the `hyprchromad` user service, and Omarchy theme and font
hooks. sudo is used only to install or remove packages with pacman. Packages
that setup builds itself are built first in a sandbox that cannot use sudo.
Issues worth reporting include:

- Command or argument injection through theme names, palette files, desktop
  entries, app or profile names, or anything else Omarchroma reads.
- Writes, deletions or restores outside the files described under
  [What it changes](README.md#what-it-changes), including through links.
- A way for a recipe, source or package that setup fetches to run code outside
  the build sandbox, or to get past the checks before `pacman -U`.
- Input that makes the panel, the service or a hook crash the shell, hang, or
  use memory without bound.

Problems in Omarchy, Hyprland or the themed apps themselves belong to those
projects.
