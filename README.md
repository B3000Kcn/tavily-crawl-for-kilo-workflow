# Kilo Crawl Workflow

This is a workflow designed for use within the Kilo environment.

## How to Use

1.  **Create the Workflow File**: Create a new workflow in Kilo named `tavilycrawl.md` and paste the content provided in the section below into it. You can choose either the English or Chinese version.
2.  **Place the Script File**: Move the `tavily-crawl-for-kilo.ps1` script into the `.kilocode\scripts` folder located in your user profile directory (e.g., `C:\Users\YourUser\.kilocode\scripts`). You may need to create this folder if it doesn't exist.
3.  **Run the Workflow**: Use or call the workflow from within Kilo.

## Important Notes

*   **Polling Functionality**: The script includes a polling mechanism for handling asynchronous API responses.
*   **API Keys**: API keys are to be entered directly at the beginning of the script file. They are not loaded from an external `.env` file.
*   **State Machine**: The script uses a state machine that is automatically created and stored as a file within your user profile's `.kilocode` directory.
*   **State Machine Reset**: The state machine will be automatically reset whenever the API keys in the script are updated.

---

# Kilo Crawl 工作流

这是一个专为 Kilo 环境设计的工作流。

## 使用方法

1.  **创建工作流文件**: 在 Kilo 中创建一个名为 `tavilycrawl.md` 的新工作流，并将下方章节提供的内容粘贴进去。你可以选择使用英文或中文版本。
2.  **放置脚本文件**: 将 `tavily-crawl-for-kilo.ps1` 脚本移动到你用户配置文件夹下的 `.kilocode\scripts` 目录中（例如 `C:\Users\YourUser\.kilocode\scripts`）。如果该文件夹不存在，你需要自行创建。
3.  **运行工作流**: 在 Kilo 中使用或调用该工作流。

## 重要提示

*   **轮询功能**: 脚本内置了用于处理异步 API 响应的轮询机制。
*   **API 密钥**: API 密钥需要直接在脚本文件的开头部分填写，而不是从外部 `.env` 文件加载。
*   **状态机**: 脚本使用一个状态机，该状态机的文件会自动在你的用户配置文件夹下的 `.kilocode` 目录中创建和存储。
*   **状态机重置**: 每当脚本中的 API 密钥更新时，状态机将自动重置。