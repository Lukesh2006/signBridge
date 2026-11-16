# Testing personal signs with more people

The cut-offs that decide **match / "Was this X?" / not recognized** live in
`backend/app/models/personal_sign_model.py` (`ACCEPT_DISTANCE`, `ACCEPT_GAP`,
`CONFIRM_DISTANCE`). They were first set from 16 clips of one signer. Before
changing them, record several different people and measure.

## 1. Record

For each volunteer (aim for **at least 5 people**, different hand sizes, skin
tones, lighting and left/right-handed):

1. Create a separate account for them in the app (each account is one signer).
2. Open **Personal Signs** and record **at least 4 signs, 5 clips each**. Use
   the same sign names for everyone (for example `hello`, `thank_you`,
   `good_morning`, `all_right`, `yes`, `no`) so the cross-person test can compare them.
3. Keep both hands and the upper body in frame; vary distance and background a little
   between clips.

Clips are saved on the BUG 2 drive under `training_samples/<user id>/<sign>/`.
They are git-ignored and never uploaded.

## 2. Measure

```powershell
cd D:\signBridge\backend
.venv\Scripts\python.exe tools\tune_personal_thresholds.py
```

The script replays the app's decision rule on every saved clip and prints, for
the current and the suggested cut-offs:

| Test | What it checks | Want |
|---|---|---|
| `same_signer` | A person's sign against their own other clips | High correct match, ~0% wrong match |
| `unknown_sign` | A sign the app was never taught | ~0% called a match |
| `cross_signer` | A person's sign against other people's clips | Shows if the seed model helps new users |

Use `--max-false-match 0.01` for a stricter target, or `--exact` to re-read the
8-frame live queries from video (slower, closest to the app).
The full report is written to `personal_models/threshold_report.json`.

## 3. Change the cut-offs

Only when the report shows at least 3–5 signers: copy the suggested values into
`personal_sign_model.py`, run the backend regression tests, and try the app again.

## First result (seed clips only, 1 signer, 4 signs, 16 clips)

| Cut-offs | Correct match | Wrong match | Untaught sign called a match |
|---|---|---|---|
| Current (0.10 / 0.004 / 0.14) | 75% | 12% | **75%** |
| Strict (0.06 / 0.004 / 0.075) | 6% | 0% | 0% |

Distance alone does not separate right from wrong on this data: the current
values let most untaught signs through, while strict values reject almost
everything. More signers are needed before choosing.
