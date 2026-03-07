# Spawn a single task from a GitHub Issue
Output docs/gifs/foundry-spawn.gif

Require gh
Require foundry

Set Shell "zsh"
Set FontSize 16
Set Width 1800
Set Height 700
Set Theme "Catppuccin Mocha"
Set Padding 20
Set TypingSpeed 50ms

# Create an issue with the foundry label
Type `gh issue create --repo merlinrabens/foundry \`
Enter
Type `  --title "Add CONTRIBUTING.md" \`
Enter
Type `  --label foundry \`
Enter
Type `  --body "Add a contributing guide with dev setup and testing instructions"`
Enter
Sleep 3s

# Foundry picks it up
Type ""
Enter
Type "foundry orchestrate ~/projects/merlinrabens/foundry"
Enter
Sleep 5s

# Check what happened
Type "foundry status"
Enter
Sleep 4s
