#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
用 GitHub 账号 + GitHub Actions(macOS) 云端编译出未签名 IPA，然后把 ipa 拉回本地。
不需要本机安装 git / gh / Xcode。

用法：
  python gh_publish.py auth            # 设备码登录，一次授权，token 存本地
  python gh_publish.py publish         # 建私有仓库、上传工程、触发构建、下载 ipa
  python gh_publish.py status          # 看最近一次构建状态
"""
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

CLIENT_ID = "178c6fc778ccc68e1d6a"  # GitHub CLI 的 OAuth App，已开启 device flow
SCOPES = "repo workflow"
API = "https://api.github.com"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOKEN_FILE = os.path.join(ROOT, ".gh_token")
REPO_NAME = "yyg-dldl-qinglin227"


def req(url, method="GET", data=None, token=None, raw=False, extra_headers=None, timeout=60):
    headers = {"Accept": "application/vnd.github+json",
               "User-Agent": "yyg-ipa-builder"}
    if token:
        headers["Authorization"] = "Bearer " + token
    body = None
    if data is not None:
        body = json.dumps(data).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if extra_headers:
        headers.update(extra_headers)
    r = urllib.request.Request(url, data=body, headers=headers, method=method)
    with urllib.request.urlopen(r, timeout=timeout) as resp:
        payload = resp.read()
        if raw:
            return resp.status, payload
        return resp.status, json.loads(payload.decode("utf-8")) if payload else {}


def load_token():
    if os.path.exists(TOKEN_FILE):
        return open(TOKEN_FILE, encoding="utf-8").read().strip()
    return None


def do_auth():
    status, j = req("https://github.com/login/device/code",
                    method="POST",
                    data={"client_id": CLIENT_ID, "scope": SCOPES},
                    extra_headers={"Accept": "application/json"})
    dc = j["device_code"]
    print("=" * 46)
    print("  1) 打开：", j["verification_uri"])
    print("  2) 输入代码：", j["user_code"])
    print("=" * 46)
    interval = int(j.get("interval", 5))
    deadline = time.time() + int(j.get("expires_in", 900))
    print("等待你在网页上点 Authorize ...")
    while time.time() < deadline:
        time.sleep(interval)
        try:
            st, res = req("https://github.com/login/oauth/access_token",
                          method="POST",
                          data={"client_id": CLIENT_ID, "device_code": dc,
                                "grant_type": "urn:ietf:params:oauth:grant-type:device_code"},
                          extra_headers={"Accept": "application/json"})
        except urllib.error.HTTPError as e:
            res = json.loads(e.read().decode("utf-8"))
        if "access_token" in res:
            open(TOKEN_FILE, "w", encoding="utf-8").write(res["access_token"])
            print("授权成功，token 已保存到：", TOKEN_FILE)
            return res["access_token"]
        err = res.get("error")
        if err == "authorization_pending":
            continue
        if err == "slow_down":
            interval += 5
            continue
        print("授权失败：", res)
        return None
    print("设备码超时，请重新运行 auth")
    return None


def collect_files():
    files = []
    skip_dirs = {".git", "out", "__pycache__"}
    for base, dirs, names in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in skip_dirs]
        for n in names:
            if n in (".gh_token",) or n.endswith(".zip"):
                continue
            p = os.path.join(base, n)
            rel = os.path.relpath(p, ROOT).replace("\\", "/")
            files.append((rel, p))
    return files


def do_publish(token):
    me = req(API + "/user", token=token)[1]
    owner = me["login"]
    print("登录账号：", owner)

    try:
        repo = req(API + f"/repos/{owner}/{REPO_NAME}", token=token)[1]
        print("仓库已存在：", repo["html_url"])
    except urllib.error.HTTPError as e:
        if e.code != 404:
            raise
        repo = req(API + "/user/repos", method="POST", token=token,
                   data={"name": REPO_NAME, "private": True,
                         "description": "斗罗大陆H5青春麒麟服 iOS 封装构建"})[1]
        print("已创建私有仓库：", repo["html_url"])
        time.sleep(3)

    branch = repo.get("default_branch") or "main"

    files = collect_files()
    print(f"上传 {len(files)} 个文件 ...")
    for rel, p in files:
        content = base64.b64encode(open(p, "rb").read()).decode("ascii")
        payload = {"message": "add " + rel, "content": content, "branch": branch}
        # 已存在则取 sha 覆盖
        sha = None
        try:
            sha = req(API + f"/repos/{owner}/{REPO_NAME}/contents/{urllib.parse.quote(rel)}",
                      token=token)[1].get("sha")
        except urllib.error.HTTPError as e:
            if e.code != 404:
                raise
        if sha:
            payload["sha"] = sha
        req(API + f"/repos/{owner}/{REPO_NAME}/contents/{urllib.parse.quote(rel)}",
            method="PUT", token=token, data=payload)
        print("  +", rel)

    print("触发 workflow ...")
    req(API + f"/repos/{owner}/{REPO_NAME}/actions/workflows/build-ipa.yml/dispatches",
        method="POST", token=token, data={"ref": branch})

    run = None
    for _ in range(30):
        time.sleep(10)
        runs = req(API + f"/repos/{owner}/{REPO_NAME}/actions/runs?per_page=5", token=token)[1]
        for r in runs.get("workflow_runs", []):
            if r["event"] == "workflow_dispatch":
                run = r
                break
        if run and run["status"] != "queued":
            break
    if not run:
        print("没找到构建任务，请打开仓库 Actions 页面查看")
        return 1
    print("构建任务：", run["html_url"])

    while run["status"] != "completed":
        time.sleep(15)
        run = req(API + f"/repos/{owner}/{REPO_NAME}/actions/runs/{run['id']}", token=token)[1]
        print("  状态：", run["status"], run.get("conclusion") or "")

    if run.get("conclusion") != "success":
        print("构建失败，日志：", run["html_url"])
        return 1

    arts = req(API + f"/repos/{owner}/{REPO_NAME}/actions/runs/{run['id']}/artifacts",
               token=token)[1]["artifacts"]
    if not arts:
        print("没有产物")
        return 1
    art = arts[0]
    print("下载产物：", art["name"], art["size"], "bytes")
    st, blob = req(art["archive_download_url"], token=token, raw=True, timeout=180)
    zpath = os.path.join(ROOT, "artifact.zip")
    open(zpath, "wb").write(blob)

    outdir = os.path.join(ROOT, "out")
    os.makedirs(outdir, exist_ok=True)
    with zipfile.ZipFile(zpath) as z:
        z.extractall(outdir)
    ipas = []
    for base, _, names in os.walk(outdir):
        for n in names:
            if n.endswith(".ipa"):
                ipas.append(os.path.join(base, n))
    print("IPA 已产出：")
    for i in ipas:
        print("  ", i, os.path.getsize(i), "bytes")
    return 0


def do_status(token):
    me = req(API + "/user", token=token)[1]
    owner = me["login"]
    runs = req(API + f"/repos/{owner}/{REPO_NAME}/actions/runs?per_page=5", token=token)[1]
    for r in runs.get("workflow_runs", []):
        print(r["status"], r.get("conclusion"), r["created_at"], r["html_url"])
    return 0


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    token = load_token()
    if cmd == "auth":
        do_auth()
    elif cmd == "publish":
        if not token:
            token = do_auth()
        sys.exit(do_publish(token))
    elif cmd == "status":
        if not token:
            print("还没授权")
            sys.exit(1)
        sys.exit(do_status(token))
    else:
        print(__doc__)
