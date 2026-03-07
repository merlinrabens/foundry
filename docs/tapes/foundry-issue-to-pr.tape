# GitHub Issue → Foundry → PR (the full flow)
Output docs/gifs/foundry-issue-to-pr.gif

Require gh
Require foundry

Set Shell "zsh"
Set FontSize 16
Set Width 1800
Set Height 800
Set Theme "Catppuccin Mocha"
Set Padding 20
Set TypingSpeed 50ms

# Step 1: Show open foundry-labeled issues
Type "# Step 1: Check for foundry-labeled issues"
Enter
Sleep 800ms

Type `gh issue list --repo merlinrabens/foundry --label foundry --state open`
Enter
Sleep 3s

# Step 2: Foundry scans and picks them up
Type ""
Enter
Type "# Step 2: Foundry scans the repo and spawns agents"
Enter
Sleep 800ms

Type "foundry orchestrate ~/projects/merlinrabens/foundry"
Enter
Sleep 5s

# Step 3: Check status
Type ""
Enter
Type "# Step 3: Check progress"
Enter
Sleep 800ms

Type "foundry status"
Enter
Sleep 4s
