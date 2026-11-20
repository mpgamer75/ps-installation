# English dictionaries

One file per source file (`<name>.psd1`), loaded with `Import-PstStrings '<name>'`.
Each entry maps the exact French source string to its English translation:

```powershell
@{
    'Rappel enregistré : {0}' = 'Reminder saved: {0}'
}
```

- Keys must match the French text passed to `L` character for character.
- Keep `{0}`, `{1}`... placeholders and their order meaning.
- A missing entry falls back to French, so nothing ever breaks.
- These are data files: only literals are allowed (restricted language).
