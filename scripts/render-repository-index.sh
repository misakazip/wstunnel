#!/usr/bin/env bash
# Generate the public landing page without exposing private signing material.
set -euo pipefail
: "${RELEASE_TAG:?Set RELEASE_TAG}"
: "${REPOSITORY_VERSION_COUNT:?Set REPOSITORY_VERSION_COUNT}"
: "${REPOSITORY_SIGNING_KEY_FINGERPRINT:?Set REPOSITORY_SIGNING_KEY_FINGERPRINT}"
repository_url=${REPOSITORY_URL:-https://wstunnel.repository.miru10.net}
fingerprint=${REPOSITORY_SIGNING_KEY_FINGERPRINT//[[:space:]]/}
fingerprint=${fingerprint^^}
[[ $RELEASE_TAG =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ $REPOSITORY_VERSION_COUNT =~ ^([1-9]|10)$ ]]
[[ $repository_url =~ ^https://[a-zA-Z0-9.-]+(:[0-9]+)?$ ]]
[[ $fingerprint =~ ^([0-9A-F]{40}|[0-9A-F]{64})$ ]]
page=$(cat <<'WSTUNNEL_REPOSITORY_HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="description" content="Unofficial signed wstunnel APT and RPM packages for Ubuntu and Enterprise Linux. Installation and signing key verification instructions.">
<title>wstunnel · Unofficial package repositories</title>
<style>
:root{color-scheme:light dark;--bg:#f6f8fb;--panel:#fff;--text:#172334;--muted:#516176;--line:#dbe3ed;--accent:#116aab}
@media(prefers-color-scheme:dark){:root{--bg:#101820;--panel:#18232e;--text:#edf3fa;--muted:#acbbcb;--line:#344455;--accent:#82c9ff}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:16px/1.65 system-ui,sans-serif}main{max-width:1000px;margin:auto;padding:48px 24px}a{color:var(--accent)}h1{font-size:clamp(2rem,5vw,3.5rem);line-height:1.12;letter-spacing:-.04em;margin:12px 0}h2{margin-top:42px}p{max-width:80ch}.eyebrow{font-size:.85rem;letter-spacing:.12em;text-transform:uppercase;color:var(--muted)}.notice{padding:16px 20px;border-left:4px solid var(--accent);background:var(--panel);border-radius:6px}nav{display:flex;gap:18px;flex-wrap:wrap;margin:26px 0}.table-wrap{overflow:auto}table{width:100%;border-collapse:collapse;background:var(--panel)}th,td{padding:12px 16px;text-align:left;border-bottom:1px solid var(--line)}pre{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:20px;overflow:auto;font-size:.85rem;line-height:1.6}code{font-family:ui-monospace,monospace}.fingerprint{overflow-wrap:anywhere;font-weight:600}footer{border-top:1px solid var(--line);margin-top:40px;padding-top:20px;color:var(--muted)}
</style>
</head>
<body><main>
<header><div class="eyebrow">Community package distribution</div>
<h1>wstunnel packages</h1>
<p>Signed APT and RPM packages built from upstream stable release tags.</p>
<p class="notice"><strong>Unofficial repositories.</strong> Maintained independently by
<a href="https://github.com/misakazip/wstunnel">misakazip</a>. These packages are not provided or maintained by
<a href="https://github.com/erebe/wstunnel">upstream wstunnel</a>.</p>
<p>Latest packaged release: <strong>@@RELEASE_TAG@@</strong> · <a href="/versions.txt">@@VERSION_COUNT@@ available versions</a></p>
</header>
<nav aria-label="Page sections"><a href="#platforms">Supported platforms</a><a href="#key">Signing key</a><a href="#ubuntu">Ubuntu installation</a><a href="#el">EL installation</a></nav>
<section id="platforms"><h2>Supported platforms</h2>
<div class="table-wrap"><table><thead><tr><th>Operating system</th><th>Architectures</th><th>Configuration</th></tr></thead><tbody>
<tr><td>Ubuntu 24.04 (noble)</td><td>amd64 / arm64</td><td><a href="/ubuntu/noble/wstunnel.sources">APT source</a></td></tr>
<tr><td>Ubuntu 26.04 (resolute)</td><td>amd64 / arm64</td><td><a href="/ubuntu/resolute/wstunnel.sources">APT source</a></td></tr>
<tr><td>Enterprise Linux 9</td><td>x86_64 / aarch64</td><td><a href="/rpm/el9/wstunnel.repo">DNF configuration</a></td></tr>
<tr><td>Enterprise Linux 10</td><td>x86_64 / aarch64</td><td><a href="/rpm/el10/wstunnel.repo">DNF configuration</a></td></tr>
</tbody></table></div>
<p>Stable upstream tags are checked daily. The latest 10 versions are retained when available.</p></section>
<section id="key"><h2>Verify the signing key</h2>
<p>Full primary key fingerprint:</p><p class="fingerprint"><code>@@SIGNING_FINGERPRINT@@</code></p>
<p>The commands below display the downloaded key and compare its full primary fingerprint with this value.
Registration stops on a mismatch or if the file contains multiple primary keys.
For independent confirmation, obtain the fingerprint from the maintainer through a trusted channel;
do not take the expected fingerprint from the downloaded key itself.</p>
<p><a href="/wstunnel.gpg">Download APT public key</a> · <a href="/RPM-GPG-KEY-wstunnel">Download RPM public key</a></p>
<p>Run each complete block in <strong>Bash</strong>. Keep the parentheses so failures stop the procedure without closing your terminal.</p></section>
<section id="ubuntu"><h2>Ubuntu 24.04 / 26.04</h2>
<pre><code>(
set -euo pipefail
sudo apt update
sudo apt install -y ca-certificates curl gnupg
repository_tmp=$(mktemp -d)
trap &#x27;rm -rf -- &quot;$repository_tmp&quot;&#x27; EXIT
curl -fsSLo &quot;$repository_tmp/wstunnel.gpg&quot; \
  @@REPOSITORY_URL@@/wstunnel.gpg
gpg --show-keys --with-fingerprint &quot;$repository_tmp/wstunnel.gpg&quot;
expected_fingerprint=&#x27;@@SIGNING_FINGERPRINT@@&#x27;
actual_fingerprint=$(gpg --batch --show-keys --with-colons &quot;$repository_tmp/wstunnel.gpg&quot; |
  awk -F: &#x27;$1 == &quot;pub&quot; { primary = 1; next }
    primary &amp;&amp; $1 == &quot;fpr&quot; { print $10; primary = 0 }&#x27;)
expected_fingerprint=$(printf &#x27;%s&#x27; &quot;$expected_fingerprint&quot; | tr -d &#x27;[:space:]&#x27; | tr &#x27;[:lower:]&#x27; &#x27;[:upper:]&#x27;)
if [[ ! $expected_fingerprint =~ ^([0-9A-F]{40}|[0-9A-F]{64})$ ||
      &quot;$actual_fingerprint&quot; != &quot;$expected_fingerprint&quot; ]]; then
  printf &#x27;Signing key fingerprint mismatch; repository registration aborted.\n&#x27; &gt;&amp;2
  exit 1
fi
printf &#x27;Signing key fingerprint verified: %s\n&#x27; &quot;$actual_fingerprint&quot;
sudo install -D -m 644 &quot;$repository_tmp/wstunnel.gpg&quot; /usr/share/keyrings/wstunnel.gpg
source /etc/os-release
curl -fsSLo &quot;$repository_tmp/wstunnel.sources&quot; \
  &quot;@@REPOSITORY_URL@@/ubuntu/$VERSION_CODENAME/wstunnel.sources&quot;
sudo install -D -m 644 &quot;$repository_tmp/wstunnel.sources&quot; /etc/apt/sources.list.d/wstunnel.sources
sudo apt update
sudo apt install wstunnel
)
</code></pre>
<p>APT checks signed repository metadata and package checksums using the key specified by <code>Signed-By</code>.
Update with <code>sudo apt update &amp;&amp; sudo apt upgrade</code>.</p>
<p>List versions with <code>apt-cache madison wstunnel</code>. To select a version:
<code>sudo apt install --allow-downgrades wstunnel=&lt;version&gt;-1</code>.</p></section>
<section id="el"><h2>Enterprise Linux 9 / 10</h2>
<p>For AlmaLinux, Rocky Linux, RHEL, and compatible distributions.</p>
<pre><code>(
set -euo pipefail
sudo dnf install -y ca-certificates curl gnupg2
repository_tmp=$(mktemp -d)
trap &#x27;rm -rf -- &quot;$repository_tmp&quot;&#x27; EXIT
curl -fsSLo &quot;$repository_tmp/RPM-GPG-KEY-wstunnel&quot; \
  @@REPOSITORY_URL@@/RPM-GPG-KEY-wstunnel
gpg --show-keys --with-fingerprint &quot;$repository_tmp/RPM-GPG-KEY-wstunnel&quot;
expected_fingerprint=&#x27;@@SIGNING_FINGERPRINT@@&#x27;
actual_fingerprint=$(gpg --batch --show-keys --with-colons &quot;$repository_tmp/RPM-GPG-KEY-wstunnel&quot; |
  awk -F: &#x27;$1 == &quot;pub&quot; { primary = 1; next }
    primary &amp;&amp; $1 == &quot;fpr&quot; { print $10; primary = 0 }&#x27;)
expected_fingerprint=$(printf &#x27;%s&#x27; &quot;$expected_fingerprint&quot; | tr -d &#x27;[:space:]&#x27; | tr &#x27;[:lower:]&#x27; &#x27;[:upper:]&#x27;)
if [[ ! $expected_fingerprint =~ ^([0-9A-F]{40}|[0-9A-F]{64})$ ||
      &quot;$actual_fingerprint&quot; != &quot;$expected_fingerprint&quot; ]]; then
  printf &#x27;Signing key fingerprint mismatch; repository registration aborted.\n&#x27; &gt;&amp;2
  exit 1
fi
printf &#x27;Signing key fingerprint verified: %s\n&#x27; &quot;$actual_fingerprint&quot;
sudo install -D -m 644 &quot;$repository_tmp/RPM-GPG-KEY-wstunnel&quot; /etc/pki/rpm-gpg/RPM-GPG-KEY-wstunnel
sudo rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-wstunnel
source /etc/os-release
el=${VERSION_ID%%.*}
curl -fsSLo &quot;$repository_tmp/wstunnel.repo&quot; \
  &quot;@@REPOSITORY_URL@@/rpm/el$el/wstunnel.repo&quot;
sudo install -D -m 644 &quot;$repository_tmp/wstunnel.repo&quot; /etc/yum.repos.d/wstunnel.repo
sudo dnf --disablerepo=&#x27;*&#x27; --enablerepo=wstunnel makecache --refresh
sudo dnf install wstunnel
)
</code></pre>
<p>The configuration enables <code>repo_gpgcheck=1</code> and <code>gpgcheck=1</code> for metadata and package signatures.
If DNF asks to import a metadata signing key, check its full fingerprint before accepting.
Update with <code>sudo dnf upgrade wstunnel</code>.</p>
<p>List versions with <code>dnf list --showduplicates wstunnel</code>.</p></section>
<footer><a href="https://github.com/misakazip/wstunnel">Source and repository maintenance</a> ·
<a href="https://github.com/erebe/wstunnel">Upstream project</a> · <a href="/versions.txt">Available versions</a></footer>
</main></body></html>
WSTUNNEL_REPOSITORY_HTML
)
page=${page//@@RELEASE_TAG@@/$RELEASE_TAG}
page=${page//@@VERSION_COUNT@@/$REPOSITORY_VERSION_COUNT}
page=${page//@@REPOSITORY_URL@@/$repository_url}
page=${page//@@SIGNING_FINGERPRINT@@/$fingerprint}
[[ $page != *'@@'* ]]
printf '%s\n' "$page"
