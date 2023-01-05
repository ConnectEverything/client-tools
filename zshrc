# This is an example of more complete integration of nats tooling
# into zsh.  You should download this once, and review, and adjust
# for taste.
#
# We cover:
#  * The _nats tab-completion
#  * Setting up NATS_CONTEXT tab-completion
#  * Other zstyle tuning
#  * run-help integration for nats

zmodload zsh/parameter   # $dirstack, $commands, $functions

# A current custom tab-completion for nats is available at:
#   https://get-nats.io/zsh.complete.nats
# and should be written to a file named "_nats" somewhere in your
# $fpath.
#
# The only directory known/portable for local zsh functions is the
# site-functions directory, only writable by root.  The nats installer will add
# the _nats completion if that directory is writeable, but otherwise just tell
# you about it.
#
# Assuming that you have ~/.zfunctions then you can try something like:
#
#   curl -O https://get-nats.io/zsh.complete.nats
#   less zsh.complete.nats   # inspect until you're comfortable
#   install zsh.complete.nats ~/.zfunctions/_nats
#   autoload _nats
#
# If you already setup autoloading for all entries, then you're fine.
#
# Almost all modern zsh installs will enable the completion system for you,
# but if not in your setup, then:
#
#   autoload compinit && compinit
#

# Next: tab-completing the name of the variable "NATS_CONTEXT"
#
# In zsh, you can tab-complete out the name of a variable which doesn't
# yet exist, by defining it in the fake-parameters context.  Then, anywhere you
# could tab-complete a real variable, this will expand too.
#
# Another approach is just to use a tool such as direnv(1) and export
# NATS_CONTEXT in .envrc files as is appropriate for your project layout.
#
if (( ${+functions[_nats]} )); then
  if zstyle -g n1 ':completion:*' fake-parameters; then
    # We already have fake-parameters defined; make the array auto-uniq
    # and add ours to it, before changing the style
    typeset -U n1
    n1+=(NATS_CONTEXT)
    zstyle ':completion:*' fake-parameters "${n1[@]}"
  else
    zstyle ':completion:*' fake-parameters NATS_CONTEXT
  fi
  unset n1
fi


# Zsh completion lets you set tuning options in a way which depends upon context
#
# If you set the verbose completion option, the tab-completion of NATS context
# names will include your context descriptions.
#
# From version v0.0.36 of the NATS CLI, it supports the --socks-proxy option for
# outbound connections.  Our completion function sets this to use URL completion,
# which you can tune using the 'urls' style.
#
# zstyle ':completion::complete:nats:*' verbose true
# zstyle ':completion::complete:nats:option--socks-proxy-1:*' urls ~/.socks-proxies


# Zsh has a built-in help system; in Emacs keybinding modes,
# this is bound by default to ESC-h and ESC-H.  In vi keybinding modes,
# you will need to bind it yourself.
#
# By default, zsh aliases run-help to man, but it also provides a more powerful
# system which falls back to invoking the manual-page viewer.  In this system,
# you can provide hooks to recognize things like specific main commands and
# sub-commands, to get specific sub-command help; this is particularly useful
# with commands such as `git`, `openssl`, and friends.
#
# If you have the run-help _function_ loaded,
# then you should remove the run-help _alias_ and use the function.
#
# Here we setup `run-help-nats`, which will provide context-specific help for
# the various nats sub-commands.
#
if (( ${+functions[run-help]} )); then
  if (( ${+aliases[run-help]} )); then
    unalias run-help
  fi

  if (( ${+commands[nats]} )); then
    function run-help-nats {
      if [[ $# -eq 0 ]]; then
        nats --help | sed -n '/^Commands/q;p' ; printf '\n=== nats cheat ===\n\n' ; nats cheat
      else
        local -a cmdwords=(); local x; for x; do [[ $x != -* ]] || break; cmdwords+=("$x"); done
        nats "${cmdwords[@]}" --help ; printf '\n=== nats cheat ===\n\n' ; nats cheat "$1"
      fi | ${=PAGER:-less}
    }
  fi
fi
