# tavilycrawl.md

## Tavily Crawl Workflow

This is a workflow for crawling public technical documentation.

### How to Use

Do not switch modes, ask any questions, list a todolist, or perform any unnecessary actions. Directly run the following command in the current mode using `PowerShell`:

```
& "$env:USERPROFILE\.kilocode\scripts\tavily-crawl-for-kilo.ps1" -Url <URL to crawl> -FolderName <Documentation folder name> [Other optional parameters]
```

### Parameter Details

*   **`-Url <string>` (Required)**
    *   **Purpose**: Specifies the root URL of the website to crawl.
    *   **Example**: `-Url "https://kilocode.ai/docs"`

*   **`-FolderName <string>` (Required)**
    *   **Purpose**: Names the folder where the documentation will be stored.
    *   **Example**: `-FolderName "KiloCode Development Docs"`

*   **`-Instructions <string>` (Optional)**
    *   **Purpose**: Provides specific crawling instructions to the Tavily API, telling it what to focus on or what rules to follow during the crawl.
    *   **Default**: None
    *   **Example**: `-Instructions "Only crawl development documentation pages"`

*   **`-MaxDepth <int>` (Optional)**
    *   **Purpose**: Sets the maximum depth for crawling. A larger value allows the crawler to follow links deeper.
    *   **Default**: `1`.
    *   **Example**: `-MaxDepth 2`

*   **`-ExtractDepth <string>` (Optional)**
    *   **Purpose**: Sets the content extraction depth.
    *   **Allowed values**: Can only be `"simple"` or `"advanced"`.
    *   **Default**: `"advanced"`.
    *   **Example**: `-ExtractDepth "simple"`

### Output

This workflow will generate the following in the project root directory:

- `.Docs`
- `.Docs/Temp`
- `.Docs/<FolderName>`

`.Docs/Temp` is used to temporarily store the structured content returned by the API and will be automatically cleared after the process is complete.

`.Docs/<FolderName>` is used to store the parsed MD documents.

### Notes

- Before running the command, you must confirm that the user has provided both a `Url` and a `FolderName`.
- If the user has not provided a `Url` or `FolderName`, please ask for them.
- If the user provides other parameters, apply them as well.
- If the user does not provide other parameters, do not ask for them; simply do not include them in the command.
- Strictly avoid using parameters that the user has not provided.