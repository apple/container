//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ArgumentParser

enum ComposeCompletionShell: String, CaseIterable, ExpressibleByArgument, Sendable {
    case bash
    case zsh
    case fish
}

/// Provides a small, host-independent completion surface. The command and
/// option lists are deliberately static; they must be regenerated when the
/// pinned Docker Compose CLI changes.
enum ComposeCompletionProvider {
    static func script(for shell: ComposeCompletionShell) -> String {
        switch shell {
        case .bash:
            return bash
        case .zsh:
            return zsh
        case .fish:
            return fish
        }
    }

    static let commands = "config convert cp create down events images kill logs ls pause port ps pull push restart rm run start stop top unpause up version watch"
    static let composeOptions =
        "--all-resources --ansi --compatibility --dry-run --env-file --file --parallel --profile --progress --project-directory --project-name --quiet-pull --verbose"
    static let pluginOptions = "--socket-path --completions"

    private static let bash = """
        # container compose completion (generated for the pinned Docker Compose CLI)
        if [[ "${_container_compose_installed:-0}" != 1 ]]; then
            _container_compose_previous_spec="$(complete -p container 2>/dev/null)" || true
            _container_compose_previous_completion=""
            if [[ "$_container_compose_previous_spec" =~ -F[[:space:]]+([^[:space:]]+) ]]; then
                _container_compose_previous_completion="${BASH_REMATCH[1]}"
            fi
        fi
        _container_compose_complete() {
            local cur="${COMP_WORDS[COMP_CWORD]}"
            if [[ "${COMP_WORDS[1]}" != "compose" ]]; then
                if [[ -n "$_container_compose_previous_completion" ]]; then
                    "$_container_compose_previous_completion" "$@"
                fi
                return
            fi
            if (( COMP_CWORD <= 2 )); then
                COMPREPLY=( $(compgen -W "\(pluginOptions) \(composeOptions) \(commands)" -- "$cur") )
            else
                COMPREPLY=( $(compgen -W "\(composeOptions) \(commands)" -- "$cur") )
            fi
        }
        if [[ -n "$_container_compose_previous_completion" ]]; then
            eval "${_container_compose_previous_spec/-F $_container_compose_previous_completion/-F _container_compose_complete}"
        else
            complete -o bashdefault -o default -F _container_compose_complete container
        fi
        _container_compose_installed=1
        """

    private static let zsh = """
        # container compose completion (generated for the pinned Docker Compose CLI)
        if (( ! ${+_container_compose_previous_completion} )); then
            typeset -g _container_compose_previous_completion="${_comps[container]-}"
        fi
        _container_compose() {
            if [[ "$words[2]" != compose ]]; then
                if [[ -n "$_container_compose_previous_completion" ]]; then
                    "$_container_compose_previous_completion" "$@"
                    return
                fi
                return 1
            fi
            if (( CURRENT == 3 )); then
                compadd -- \(pluginOptions) \(composeOptions) \(commands)
            else
                compadd -- \(composeOptions) \(commands)
            fi
        }
        compdef _container_compose container
        """

    private static let fish = """
        # container compose completion (generated for the pinned Docker Compose CLI)
        complete -c container -n 'test (count (commandline -opc)) -eq 2; and test (commandline -opc)[2] = compose' -a '\(pluginOptions) \(composeOptions) \(commands)'
        complete -c container -n 'test (count (commandline -opc)) -gt 2; and test (commandline -opc)[2] = compose' -a '\(composeOptions) \(commands)'
        """
}
