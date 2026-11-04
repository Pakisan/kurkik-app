# The look of the recording, and a demo shell set up off camera.
# Run from the repository's root, with the demo's systems up and seeded: vhs demo/tapes/tour.tape
Set Shell "bash"
Set FontSize 18
Set Width 1440
Set Height 860
Set Padding 24
Set Theme "Catppuccin Mocha"
Set TypingSpeed 45ms
Set CursorBlink false

Hide
Type "source demo/env.sh > /dev/null && cd demo && export PS1='$ ' && clear"
Enter
Sleep 500ms
Show
