#!/bin/sh
# Generates the benchmark/test corpus with macOS text-to-speech: 16 kHz mono
# 16-bit WAVs in bench/audio, plus bench/audio/corpus.tsv (file, language,
# reference text). Synthetic speech, so the numbers are reproducible on any
# Mac and no personal audio is involved. The WAVs are not committed.
set -e
cd "$(dirname "$0")"
mkdir -p audio
out=audio/corpus.tsv
: > "$out"

clip() { # name voice lang text
  say -v "$2" -o "audio/$1.wav" --data-format=LEI16@16000 "$4"
  printf '%s\t%s\t%s\n' "$1" "$3" "$4" >> "$out"
}

clip tiny       Samantha en "Send it."
clip yes        Daniel   en "Yes, that works for me."
clip short      Samantha en "Please schedule the design review for Thursday afternoon and invite the whole team."
clip email      Karen    en "Hi Sarah, thanks for the update. I reviewed the numbers and they look good, so let's go ahead with the plan we discussed on Monday."
clip code       Daniel   en "Rename the function parse config to load settings, and make it return an optional instead of throwing an error."
clip numbers    Moira    en "The meeting moved to March fourteenth at three thirty, room two hundred and twelve, and the budget is forty five thousand dollars."
clip note       Samantha en "Remember to pick up the dry cleaning, call the dentist about the appointment next week, and buy milk, eggs and bread on the way home."
clip paragraph  Daniel   en "When the service runs for several days, memory has to stay flat. Every buffer has a fixed size, every queue has a limit, and anything that cannot keep up is dropped and counted instead of piling up. That is what keeps the latency the same on day five as on day one."
clip long       Karen    en "This is a longer dictation to exercise the path where speech runs past a single thirty second window. The model processes audio in thirty second chunks, so anything longer has to be split and the pieces stitched back together. We want to make sure nothing is lost at the boundary, that the words on either side of it come through in the right order, and that the whole thing still finishes quickly enough that the person dictating does not sit and wait. A good dictation tool feels like typing, only faster, and it should never make you wonder whether it heard you at all. If it is slow or unreliable, people stop using it, no matter how accurate it is on a good day."
clip german     Anna     de "Bitte schicken Sie mir den Bericht bis Freitag, damit wir ihn in der nächsten Sitzung besprechen können."
clip lithuanian Ona      lt "Labas rytas, ar galėtumėte atsiųsti man susitikimo darbotvarkę iki rytojaus?"

echo "wrote $(wc -l < "$out" | tr -d ' ') clips to bench/audio"
