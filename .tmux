if tmux has-session -t tml 2>/dev/null; then
  tmux attach -t tml
  exit
fi

tmux new-session -d -s tml -n nvim -x $(tput cols) -y $(tput lines)

tmux new-window -t tml -n zsh

tmux attach -t tml:nvim

