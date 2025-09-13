# tavilycrawl.md

## Tavily Crawl Workflow

这是一个爬取公开技术文档的工作流。

### 使用方法

不要切换模式，不要问任何问题，不要列 Todolist，不要有任何多余的动作，直接当前模式下使用`PowerShell`运行以下命令：

```
& "$env:USERPROFILE\.kilocode\scripts\tavily-crawl-for-kilo.ps1" -Url <你要抓取的网址> -FolderName <文档文件夹名称> [其他可选参数]
```

### 参数详解

*   **`-Url <string>` (必需)**
    *   **作用**: 指定抓取的网站的根 URL。
    *   **示例**: `-Url "https://kilocode.ai/docs"`

*   **`-FolderName <string>` (必需)**
    *   **作用**: 命名文档存放的文件夹。
    *   **示例**: `-FolderName "KiloCode开发文档"`

*   **`-Instructions <string>` (可选)**
    *   **作用**: 向 Tavily API 提供特定的抓取指令，告诉它在抓取时应该关注什么内容或者遵循什么规则。
    *   **默认值**: 无
    *   **示例**: `-Instructions "Only crawl development documentation pages"`

*   **`-MaxDepth <int>` (可选)**
    *   **作用**: 设置抓取的最大深度。数值越大，爬虫会顺着链接深入得越远。
    *   **默认值**: `1`。
    *   **示例**: `-MaxDepth 2`

*   **`-ExtractDepth <string>` (可选)**
    *   **作用**: 设置内容的提取深度。
    *   **可选值**: 只能是 `"simple"` 或 `"advanced"`。
    *   **默认值**: `"advanced"`。
    *   **示例**: `-ExtractDepth "simple"`

### 产出

本工作流将会在项目根目录生成：

- `.Docs`
- `.Docs/Temp`
- `.Docs/<FolderName>`

`.Docs/Temp`用于临时存放 API 返回的结构话内容，流程结束后会自动清除。

`.Docs/<FolderName>`用于存放解析后的 MD 文档。

### 注意事项

- 在运行命令前，必须确认用户已经提供了 Url 和 FolderName。
- 若用户未提供 Url 或 FolderName，请向用户索要。
- 如果用户同时提供了其他参数，也请一并应用。
- 若用户未提供其他参数，也不要向用户索要，不在命令中应用它们即可。
- 严禁擅自使用用户未提供的参数。