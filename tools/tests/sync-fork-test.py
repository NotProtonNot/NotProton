#!/usr/bin/env python3
"""Exercise atomic fork sync and conflict resumption using disposable Git repositories."""
from pathlib import Path
import subprocess
import tempfile

SCRIPT = Path(__file__).resolve().parents[1] / 'sync-fork.py'
def cmd(*args, cwd=None, check=True):
    return subprocess.run(args, cwd=cwd, text=True, capture_output=True, check=check)
def git(repo, *args, check=True): return cmd('git', *args, cwd=repo, check=check)
def write(repo, name, text):
    path = repo / name; path.write_text(text)
def commit(repo, message):
    git(repo, 'add', '.'); git(repo, 'commit', '-m', message)
with tempfile.TemporaryDirectory(prefix='np-sync-test-') as tmp:
    root=Path(tmp); origin=root/'origin.git'; upstream=root/'upstream.git'; seed=root/'seed'; local=root/'local'
    cmd('git','init','--bare',str(origin)); cmd('git','init','--bare',str(upstream)); cmd('git','init','-b','main',str(seed))
    for key,value in [('user.name','Sync test'),('user.email','sync@example.invalid')]: git(seed,'config',key,value)
    git(seed,'remote','add','origin',str(origin));git(seed,'remote','add','upstream',str(upstream))
    write(seed,'shared.txt','base\n');commit(seed,'base');git(seed,'push','origin','main');git(seed,'push','upstream','main')
    git(seed,'switch','-c','feature/example');write(seed,'feature.txt','keep feature\n');commit(seed,'feature');feature=git(seed,'rev-parse','HEAD').stdout.strip();git(seed,'push','origin','HEAD')
    git(seed,'switch','main');git(seed,'switch','-c','dev');write(seed,'dev.txt','keep dev\n');commit(seed,'dev');git(seed,'push','origin','HEAD')
    git(seed,'switch','main');write(seed,'upstream.txt','new upstream\n');commit(seed,'upstream');target=git(seed,'rev-parse','HEAD').stdout.strip();git(seed,'push','upstream','main')
    cmd('git','clone','-b','main',str(origin),str(local));git(local,'remote','add','upstream',str(upstream))
    for key,value in [('user.name','Sync test'),('user.email','sync@example.invalid')]: git(local,'config',key,value)
    write(local,'untracked-user.txt','do not touch\n');before=git(local,'status','--porcelain').stdout;head=git(local,'rev-parse','HEAD').stdout
    result=cmd('python3',str(SCRIPT),'--push',cwd=local,check=False)
    assert result.returncode==0,(result.stdout,result.stderr)
    assert git(local,'status','--porcelain').stdout==before and git(local,'rev-parse','HEAD').stdout==head
    git(local,'fetch','origin')
    for branch in ['main','dev','feature/example']:
        assert git(local,'merge-base','--is-ancestor',target,'origin/'+branch,check=False).returncode==0,branch
        assert git(local,'merge-base','--is-ancestor','origin/main','origin/'+branch,check=False).returncode==0,branch
    assert git(local,'merge-base','--is-ancestor',feature,'origin/feature/example',check=False).returncode==0
    # New conflicting edits must leave every remote branch unchanged until resolved.
    git(seed,'fetch','origin');git(seed,'switch','-C','feature/example','origin/feature/example');write(seed,'shared.txt','feature change\n');commit(seed,'feature conflict');git(seed,'push','origin','HEAD')
    git(seed,'switch','main');write(seed,'shared.txt','upstream change\n');commit(seed,'upstream conflict');target2=git(seed,'rev-parse','HEAD').stdout.strip();git(seed,'push','upstream','main')
    refs_before=cmd('git','--git-dir',str(origin),'for-each-ref','--format=%(refname) %(objectname)','refs/heads').stdout
    failed=cmd('python3',str(SCRIPT),'--push',cwd=local,check=False)
    assert failed.returncode!=0 and 'Merge needs attention' in failed.stderr,(failed.stdout,failed.stderr)
    assert cmd('git','--git-dir',str(origin),'for-each-ref','--format=%(refname) %(objectname)','refs/heads').stdout==refs_before
    session=Path(next(line.removeprefix('Sync session: ') for line in failed.stdout.splitlines() if line.startswith('Sync session: ')))
    checkout=session/'checkout';write(checkout,'shared.txt','feature change\nupstream change\n');git(checkout,'add','shared.txt')
    continued=cmd('python3',str(SCRIPT),'--continue',str(session),'--push',cwd=local,check=False)
    assert continued.returncode==0,(continued.stdout,continued.stderr)
    git(local,'fetch','origin')
    assert git(local,'merge-base','--is-ancestor',target2,'origin/feature/example',check=False).returncode==0
    assert git(local,'show','origin/feature/example:shared.txt').stdout=='feature change\nupstream change\n'
    assert git(local,'status','--porcelain').stdout==before and git(local,'rev-parse','HEAD').stdout==head
print('sync-fork: feature histories preserved; atomic push, conflict resume and dirty checkout isolation pass')
