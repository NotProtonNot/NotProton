#!/usr/bin/env python3
"""Merge upstream's default branch into every fork branch without touching checkouts."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import uuid


def run(*args, cwd=None, check=True, capture=False):
    result = subprocess.run(args, cwd=cwd, text=True, stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None)
    if check and result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {' '.join(args)}\n{result.stderr or ''}")
    return result.stdout.strip() if capture else result.returncode


def git(*args, cwd=None, **kw):
    return run('git', *args, cwd=cwd, **kw)


def save(path, state):
    temp = path.with_suffix('.new')
    temp.write_text(json.dumps(state, indent=2) + '\n')
    os.replace(temp, path)


def checks(wd):
    git('diff', '--check', 'HEAD^1', 'HEAD', cwd=wd)
    launcher = wd / 'dylib/feats/compat_run.sh'
    if launcher.exists(): run('sh', '-n', str(launcher))
    makefile = wd / 'Makefile'
    if not makefile.exists(): return
    text = makefile.read_text()
    wanted = ['compatsvc-check', 'panel-behavior', 'scriptcheck', 'launchercheck',
              'bundlecheck', 'gameenv-check', 'display-check', 'cursor-check',
              'launchperfcheck', 'runnervariantcheck', 'confcheck']
    targets = [name for name in wanted if re.search(r'^' + re.escape(name) + r'\s*:', text, re.M)]
    if targets: run('make', *targets, cwd=wd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--push', action='store_true', help='Push all verified branch updates atomically')
    parser.add_argument('--continue', dest='resume', type=Path, metavar='SESSION', help='Resume a resolved conflict')
    args = parser.parse_args()
    repo = Path(git('rev-parse', '--show-toplevel', capture=True))
    common = Path(git('rev-parse', '--path-format=absolute', '--git-common-dir', capture=True))
    if args.resume:
        session = args.resume.resolve()
        if session.parent != (common / 'notproton-sync').resolve():
            raise RuntimeError('Session must be inside this repository’s notproton-sync directory')
        statefile = session / 'state.json'
        state = json.loads(statefile.read_text())
        wd = session / 'checkout'
    else:
        remotes = git('remote', cwd=repo, capture=True).splitlines()
        if 'origin' not in remotes: raise RuntimeError('Missing fork remote origin')
        if 'upstream' not in remotes:
            git('remote', 'add', 'upstream', 'https://github.com/NotProtonNot/NotProton.git', cwd=repo)
        git('fetch', '--prune', 'origin', cwd=repo)
        git('fetch', 'upstream', cwd=repo)
        target = git('rev-parse', 'upstream/main^{commit}', cwd=repo, capture=True)
        refs = git('for-each-ref', '--format=%(refname) %(objectname) %(symref)', 'refs/remotes/origin/',
                   cwd=repo, capture=True).splitlines()
        branches = []
        for line in refs:
            fields = line.split()
            if len(fields) != 2: continue  # Exclude the symbolic origin/HEAD.
            name = fields[0].removeprefix('refs/remotes/origin/')
            branches.append({'name': name, 'old': fields[1]})
        if not branches: raise RuntimeError('No origin branches were found')
        session = common / 'notproton-sync' / (time.strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:8])
        session.mkdir(parents=True)
        wd = session / 'checkout'
        statefile = session / 'state.json'
        state = {'target': target, 'branches': branches, 'index': 0, 'results': {}, 'in_merge': False}
        save(statefile, state)
        git('worktree', 'add', '--detach', str(wd), branches[0]['old'], cwd=repo)
    print(f"Sync session: {session}\nUpstream commit: {state['target']}", flush=True)
    while state['index'] < len(state['branches']):
        branch = state['branches'][state['index']]
        name, old = branch['name'], branch['old']
        print(f"Checking {name}", flush=True)
        if state.get('pending_branch') == name:
            if git('status', '--porcelain', cwd=wd, capture=True):
                raise RuntimeError(f'Commit verification fixes in {wd}, then rerun --continue {session}')
        elif state['in_merge']:
            if git('diff', '--name-only', '--diff-filter=U', cwd=wd, capture=True):
                raise RuntimeError(f'Unresolved merge in {wd}; resolve and stage it, then rerun with --continue {session}')
            git('-c', 'rerere.enabled=true', '-c', 'core.editor=true', 'merge', '--continue', cwd=wd)
            state['in_merge'] = False
        else:
            if git('status', '--porcelain', cwd=wd, capture=True):
                raise RuntimeError(f'The sync checkout has unexpected changes: {wd}')
            git('switch', '--detach', old, cwd=wd)
            if git('merge-base', '--is-ancestor', state['target'], old, cwd=wd, check=False) != 0:
                state['in_merge'] = True
                save(statefile, state)
                rc = git('-c', 'rerere.enabled=true', '-c', 'rerere.autoupdate=true',
                         '-c', 'core.editor=true', 'merge', '--no-edit', '--no-ff', state['target'], cwd=wd, check=False)
                if rc:
                    raise RuntimeError(f'Merge needs attention in {wd}; resolve and stage it, then rerun with --continue {session}')
                state['in_merge'] = False
        state['pending_branch'] = name
        save(statefile, state)
        new = git('rev-parse', 'HEAD', cwd=wd, capture=True)
        if git('merge-base', '--is-ancestor', old, new, cwd=wd, check=False):
            raise RuntimeError(f'{name} would discard existing history')
        if new != old: checks(wd)
        state['results'][name] = new
        state.pop('pending_branch', None)
        state['index'] += 1
        save(statefile, state)
    if args.push:
        git('fetch', '--prune', 'origin', cwd=repo)
        current = git('for-each-ref', '--format=%(refname) %(objectname) %(symref)', 'refs/remotes/origin/', cwd=repo, capture=True).splitlines()
        observed = {parts[0].removeprefix('refs/remotes/origin/'): parts[1] for line in current if len(parts := line.split()) == 2}
        expected = {branch['name']: branch['old'] for branch in state['branches']}
        if observed != expected: raise RuntimeError('Fork branches changed during sync; start again from their new tips')
        refspecs = [f"{state['results'][b['name']]}:refs/heads/{b['name']}" for b in state['branches']]
        # The explicit credential helper avoids macOS keychain picking an unrelated GitHub account.
        if shutil.which('gh') and subprocess.run(['gh', 'auth', 'status'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
            git('-c', 'credential.helper=', '-c', 'credential.helper=!gh auth git-credential',
                'push', '--atomic', 'origin', *refspecs, cwd=repo)
        else: git('push', '--atomic', 'origin', *refspecs, cwd=repo)
        print('All fork branches pushed atomically.', flush=True)
    else:
        print('Verified locally; rerun with --continue ' + str(session) + ' --push to publish.', flush=True)
        return
    git('worktree', 'remove', '--force', str(wd), cwd=repo)
    state['pushed'] = True
    save(statefile, state)


if __name__ == '__main__':
    try: main()
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        print(f'sync-fork: {error}', file=sys.stderr)
        sys.exit(1)
