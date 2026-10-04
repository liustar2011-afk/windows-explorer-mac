Added focus routing and regression tests.
Initial test: 137 passed, 1 failed. Text-field hit test used an incorrect coordinate space. Replaced hit test with native text-editor bounds converted to window coordinates.
Final build: 138 passed, 0 failed. Installed and packaged; signature and binary match verified. Native UI confirms clicking a file exits search focus and Cmd+C displays 已复制 1 个项目. Existing copy/paste transfer tests pass.
