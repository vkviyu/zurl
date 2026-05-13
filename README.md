# zurl

交互式 API 测试工具。基于 Zig + libcurl 构建，极低内存占用，支持环境变量、请求集合、缓存重放、HAR 导出，以及通过 curl 透传原生支持 SSE。

```
zurl(prod)> GET {{BASE_URL}}/users/me -H "Authorization: Bearer {{TOKEN}}" -p
HTTP 200  (128ms)
{
  "id": 42,
  "name": "zhaozhiqiang",
  "role": "admin"
}
```

## 安装

### 前置依赖

- [Zig](https://ziglang.org/download/) >= 0.15.2
- libcurl（系统级安装）
  - macOS: `brew install curl`（系统自带通常已足够）
  - Ubuntu/Debian: `sudo apt install libcurl4-openssl-dev`
  - Arch: `sudo pacman -S curl`

### 构建

```bash
git clone <repo-url>
cd zurl
zig build
```

编译产物位于 `./zig-out/bin/zurl`。

### 运行

```bash
./zig-out/bin/zurl
# 或
zig build run
```

启动后进入交互式 REPL：

```
zurl v0.1.0 - Interactive API Testing Tool
Type 'help' for available commands.

zurl(default)>
```

---

## 快速上手

### 1. 创建环境并设置变量

```
zurl(default)> env create dev
Created environment: dev
zurl(default)> env use dev
Switched to: dev
zurl(dev)> set BASE_URL https://httpbin.org
Set BASE_URL = https://httpbin.org
```

### 2. 发送请求

```
zurl(dev)> GET {{BASE_URL}}/get -p
HTTP 200  (234ms)
{
  "args": {},
  "headers": {
    "Accept": "*/*",
    "Host": "httpbin.org"
  },
  "origin": "1.2.3.4",
  "url": "https://httpbin.org/get"
}
```

### 3. 带请求头和请求体

```
zurl(dev)> POST {{BASE_URL}}/post -H "Content-Type: application/json" -d '{"name":"zurl"}' -p
HTTP 200  (198ms)
{
  "json": {
    "name": "zurl"
  },
  ...
}
```

### 4. 导出 HAR

```
zurl(dev)> export api_test.har
Exported 2 entries to api_test.har
```

---

## 命令参考

### HTTP 请求

支持所有标准 HTTP 方法：`GET` `POST` `PUT` `DELETE` `PATCH` `HEAD` `OPTIONS`

```
METHOD <url> [选项]
```

| 选项               | 说明                                  |
| ------------------ | ------------------------------------- |
| `-H "Name: Value"` | 添加请求头                            |
| `-d <body>`        | 设置请求体                            |
| `-L`               | 跟随重定向                            |
| `-e <env>`         | 临时使用指定环境（不切换当前环境）    |
| `-p`               | 美化输出（JSON 缩进 / HTML 标签缩进） |
| `-g <group>`       | 将请求保存到命名分组（永久）          |

URL 和请求头/请求体中的 `{{VAR}}` 会被自动替换为当前环境中的变量值。

**示例：**

```
GET https://api.example.com/users
POST https://api.example.com/login -H "Content-Type: application/json" -d '{"user":"admin","pass":"123"}'
PUT {{BASE_URL}}/users/1 -d '{"name":"new"}' -H "Authorization: Bearer {{TOKEN}}" -p
DELETE {{BASE_URL}}/users/1 -L
GET {{BASE_URL}}/status -e prod
POST {{BASE_URL}}/orders -g order-flow
```

### curl 透传

```
curl [任意 curl 参数] <url>
```

直接调用系统 curl，支持 `{{VAR}}` 变量替换。输出实时流式打印，**天然支持 SSE**：

```
zurl(dev)> curl -N {{BASE_URL}}/events/stream
data: {"event":"order.created","id":1}

data: {"event":"order.updated","id":1}

^C
Curl interrupted.
```

### 请求集合

```
load <file.json>          加载 JSON 集合文件
list                      列出集合中的所有请求
run <name|index>          按名称或索引执行单个请求
run all                   按顺序执行全部请求
```

**集合文件格式** (参见 `examples/demo.json`)：

```json
{
  "name": "用户模块测试",
  "requests": [
    {
      "name": "登录",
      "request": {
        "method": "POST",
        "url": "{{BASE_URL}}/auth/login",
        "headers": {
          "Content-Type": "application/json"
        },
        "body": {
          "username": "admin",
          "password": "123456"
        }
      },
      "capture": {
        "TOKEN": "$.token",
        "USER_ID": "$.userId"
      }
    },
    {
      "name": "获取用户详情",
      "request": {
        "method": "GET",
        "url": "{{BASE_URL}}/users/{userId}",
        "pathParams": {
          "userId": "{{USER_ID}}"
        },
        "headers": {
          "Authorization": "Bearer {{TOKEN}}"
        }
      }
    }
  ]
}
```

**关键能力：**

- **变量捕获** — `capture` 字段使用 JSONPath (`$.field`) 从响应中提取值并自动写入环境变量，后续请求可直接引用
- **路径参数** — `{userId}` 风格的占位符通过 `pathParams` 或环境变量替换
- **链式请求** — `run all` 按顺序执行，前一个请求 capture 的变量自动传递给后续请求

### 环境管理

```
env create <name>         创建新环境
env use <name>            切换当前环境
env set <k> <v> [...]     设置变量（支持多对 key value）
env list                  列出所有环境
set <k> <v> [...]         env set 的快捷方式
vars                      显示当前环境的变量
vars <env_name>           显示指定环境的变量
```

变量支持引号包裹的值：

```
zurl(dev)> set TOKEN "eyJhbGciOiJIUzI1NiJ9..." NAME "Zhang San"
Set TOKEN = eyJhbGciOiJIUzI1NiJ9...
Set NAME = Zhang San
```

### 请求缓存与重放

每次通过 HTTP 方法发送的请求会自动进入滚动缓存（最近 10 条）。缓存保存的是**模板**（含 `{{VAR}}` 占位符），重放时使用当前环境的变量重新替换。

```
cache                     查看当前环境的缓存
cache <env_name>          查看指定环境的缓存
replay <index>            重放指定缓存条目
replay <index> -s <env>   从其他环境读取模板，在当前环境执行
```

#### 命名分组

使用 `-g` 标志将请求保存到永久分组：

```
zurl(dev)> POST {{BASE_URL}}/login -d '{"user":"admin"}' -g auth-flow
  [saved to group 'auth-flow']

zurl(dev)> GET {{BASE_URL}}/me -H "Authorization: Bearer {{TOKEN}}" -g auth-flow
  [saved to group 'auth-flow']

zurl(dev)> groups
  auth-flow (2 entries)

zurl(dev)> groups auth-flow
Group 'auth-flow' (2 entries):
  [0] POST {{BASE_URL}}/login  [body]
  [1] GET {{BASE_URL}}/me

zurl(dev)> replay -g auth-flow all
```

**典型用法：** 在 dev 环境构建请求模板并分组，然后切换到 prod 环境重放：

```
zurl(dev)> env use prod
zurl(prod)> replay -g auth-flow all
```

### 历史与导出

```
history                   显示请求历史（方法、URL、状态码、耗时）
export [file.har]         导出为 HAR 1.2 格式（默认 zurl_export.har）
```

导出的 HAR 文件包含完整的请求/响应信息和详细的时间分解（DNS、连接、SSL、发送、等待、接收），可直接导入 Chrome DevTools 或其他工具分析。

### 其他

```
clear / cls               清屏
quit / exit               退出
help                      显示帮助
```

---

## 变量插值

zurl 支持两种模板语法：

| 语法      | 说明                                        | 示例               |
| --------- | ------------------------------------------- | ------------------ |
| `{{VAR}}` | 环境变量                                    | `{{BASE_URL}}/api` |
| `{param}` | 路径参数（集合模式，优先匹配 `pathParams`） | `/users/{userId}`  |

插值在以下位置生效：URL、请求头值、请求体、curl 命令参数。

未匹配的占位符会原样保留，不会报错。

---

## 持久化

所有环境变量、缓存条目和命名分组会自动保存到 `zurl.json`（当前工作目录）。

可通过环境变量 `ZURLENV` 指定自定义路径：

```bash
ZURLENV=~/projects/myapi/zurl.json ./zig-out/bin/zurl
```

这样不同项目可以维护各自独立的环境和缓存配置。

---

## 项目结构

```
src/
  main.zig        入口：REPL 循环 + 信号处理
  App.zig         应用上下文 + 命令分发
  executor.zig    统一请求执行引擎
  client.zig      libcurl HTTP 客户端封装
  config.zig      JSON 集合文件解析
  env.zig         环境变量管理
  cache.zig       请求缓存（滚动缓冲 + 命名分组）
  store.zig       持久化层（JSON 序列化/反序列化）
  interpolate.zig 模板变量插值
  format.zig      响应美化（JSON/HTML）
  har.zig         HAR 1.2 导出
  json.zig        JSON 工具函数
  args.zig        参数解析工具
  sse.zig         SSE 流式解析器
  curl_parser.zig curl 命令语法解析
  curl_import.zig curl 文件导入（转集合 JSON）
examples/
  demo.json       示例请求集合
  curls.txt       示例 curl 命令文件（配合 import 使用）
```

---

## License

MIT
