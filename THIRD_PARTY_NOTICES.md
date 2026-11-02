# Third-party notices

## Sentient OS

Parts of ClickBait's notch window, hotkey handling and permission guide are adapted from Sentient OS (https://github.com/Sentient-OS-Labs/sentient-os, commit 16e871a), licensed under the GNU Affero General Public License v3.0 (the same licence as ClickBait; full text in [LICENSE](LICENSE)). Copyright (c) Sentient OS Labs and the Sentient OS contributors. Adapted code is marked "adapted from Sentient OS" where it appears and was modified by the ClickBait contributors from 2026-10-21.

## PermissionFlow

ClickBait's permission guide (`PermissionGuide`, `SettingsWindowTracker`) is adapted, through Sentient OS, from PermissionFlow (https://github.com/jaywcjlove/PermissionFlow).

```
MIT License

Copyright (c) 2026 小弟调调

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Notch panel look

ClickBait's notch panel adapts a palette, cards, header tabs, player controls, sizes and motion from MIT-licensed code by Louis Raillé.

```
MIT License

Copyright (c) 2026 Louis Raillé

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

```

## Vorssaint

`ClickBait/Agents/agent-prices.json` is Vorssaint's list of the providers' published API prices
(https://github.com/vorssaint/vorssaint-utils, `Resources/agent-prices.json`, updated 2026-10-30),
copied unchanged. Vorssaint is © 2026 Vorssaint, licensed under the GNU General Public License,
version 3 or later; ClickBait is AGPL-3.0, which GPL-3.0 code may be combined with. ClickBait's
AI Agents page, notch bubbles, gallery, timer and Claude Code / Codex usage reading follow
Vorssaint's design and approach (the `get_usage` control request, `codex app-server`'s
`account/read`, reading session logs for counters only), written anew for ClickBait.
The volume mixer follows Vorssaint's (a process tap per app, no driver), written anew for ClickBait.
