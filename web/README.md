# Mac Typer 官网 + 在线打字练习

Go 标准库实现的网站，无第三方依赖，编译成单个二进制（页面和静态文件都已内嵌）。

- `/`：Mac Typer 产品落地页（功能、FAQ、下载）
- `/typing`：中英文打字测速（WPM / CPM、准确率、实时高亮），带排行榜
- `/api/scores`：排行榜 `GET ?mode=en|zh` 与 `POST` 提交；速度由服务端根据字数和时长计算，并有合理范围校验和每 IP 10 秒限流
- `/api/version`：最新版本号和下载地址，可供 App 检查更新
- `/robots.txt`、`/sitemap.xml`、canonical/OG 标签：SEO 基础
- AdSense 广告位：配置 `ADSENSE_CLIENT` 和 `ADSENSE_SLOT` 后才会显示

## 本地运行

```bash
cd web && go run .
```

打开 http://localhost:8080 。成绩保存在 `./data/scores.json`。

```bash
go test -race ./...
```

## 部署到云服务器（Docker + Caddy 自动 HTTPS）

1. 购买域名，把 `A` 记录（如需 www，再加 `www` 记录）指向服务器 IP；放行 80/443 端口。
   国内服务器需要先完成 ICP 备案，香港/海外服务器不需要。
2. 在服务器上安装 Docker，然后：

```bash
git clone https://github.com/Ronin-TFT/mac-typer.git && cd mac-typer/web
cp .env.example .env   # 修改 DOMAIN 和 SITE_URL
docker compose up -d --build
```

Caddy 会自动申请并续期证书。更新代码后执行 `git pull && docker compose up -d --build`。
排行榜数据在 Docker 卷 `scores` 中，重建容器不会丢失。

## 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `ADDR` | `:8080` | 监听地址 |
| `DATA_DIR` | `./data` | 排行榜存储目录 |
| `SITE_URL` | `http://localhost:8080` | 站点完整地址，用于 canonical 和 sitemap |
| `APP_VERSION` | `1.0.2` | 页面和 `/api/version` 显示的版本 |
| `DOWNLOAD_URL` | GitHub 最新 Release | 下载按钮地址 |
| `REPO_URL` | GitHub 仓库 | 仓库链接 |
| `ADSENSE_CLIENT` / `ADSENSE_SLOT` | 空 | 填写后显示广告 |
| `TRUST_PROXY` | 空 | 设为 `1` 时从 `X-Forwarded-For` 取客户端 IP（compose 中已开启） |

## 引流与变现建议

- 在 Google Search Console 和百度站长平台提交 `sitemap.xml`。
- 增加更多长尾页面，例如"五笔打字练习""英语单词打字""程序员代码打字"，每个页面单独一个 URL。
- 练习文本只能用原创或有授权的内容。
- 广告收入要等流量起来后才会有，早期更值得做的是把访客导向 Mac Typer 下载和 GitHub Star。
