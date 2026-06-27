# TypelessMLX Python 环境手动安装指南

适用场景：自动安装失败、企业内网、自签证书等情况。

---

## 方式一：uv（推荐）

### 前置条件

安装 [uv](https://docs.astral.sh/uv/getting-started/installation/)：

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

### 安装步骤

```bash
# 建 venv（uv 会自动下载 Python 3.12）
uv venv ~/.local/share/typelessmlx/venv --python 3.12

# 装包
REQ="/Applications/TypelessMLX.app/Contents/Resources/backend/requirements.txt"
uv pip install \
  -p ~/.local/share/typelessmlx/venv/bin/python \
  -r "$REQ"
```

---

## 方式二：Homebrew Python + pip（企业内网 / 证书问题）

uv 使用内置 TLS 实现，不读取系统证书文件。如遇 `invalid peer certificate` 报错，改用此方式。

### 前置条件

```bash
brew install python@3.12
```

### 安装步骤

```bash
# 建 venv
python3.12 -m venv ~/.local/share/typelessmlx/venv

# 装包（普通网络）
REQ="/Applications/TypelessMLX.app/Contents/Resources/backend/requirements.txt"
~/.local/share/typelessmlx/venv/bin/pip install -r "$REQ"

# 装包（企业内网，指定证书）
SSL_CERT_FILE=~/combined_cert.pem \
REQUESTS_CA_BUNDLE=~/combined_cert.pem \
~/.local/share/typelessmlx/venv/bin/pip install -r "$REQ"
```

### 可选：PyPI 镜像加速

```bash
SSL_CERT_FILE=~/combined_cert.pem \
REQUESTS_CA_BUNDLE=~/combined_cert.pem \
~/.local/share/typelessmlx/venv/bin/pip install \
  -i https://mirrors.aliyun.com/pypi/simple/ \
  -r "$REQ"
```

---

## 验证安装

```bash
~/.local/share/typelessmlx/venv/bin/python \
  -c "import mlx_whisper, mlx_audio, huggingface_hub; print('OK')"
```

输出 `OK` 表示安装成功。打开 TypelessMLX.app，点"重新检查"即可。

---

## 常见问题

**pip 仍然报证书错误**

将证书一次性导入系统钥匙串，之后所有工具自动信任：

```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain \
  ~/combined_cert.pem
```

**pip 版本过旧**

```bash
~/.local/share/typelessmlx/venv/bin/pip install --upgrade pip
```

**固定使用镜像源**

编辑（或新建）`~/.pip/pip.conf`：

```ini
[global]
index-url = https://mirrors.aliyun.com/pypi/simple/
trusted-host = mirrors.aliyun.com
```
