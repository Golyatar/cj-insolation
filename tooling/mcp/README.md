# SketchUp CJ MCP

Локальный MCP-сервер с пятью инструментами. Работает через STDIO и наш Ruby-мост,
без дополнительных Python-пакетов, сетевых портов и ключей API.

## Инструменты

| Имя | Назначение |
|---|---|
| `sketchup_status` | Состояние моста, версия SketchUp, количество объектов |
| `sketchup_reload_plugin` | Перезагрузка `src/cj.rb` в текущем сеансе |
| `sketchup_run_checks` | Базовые проверки и JSON-отчёт |
| `sketchup_run_geometry_tests` | Временная стена и конус, тесты пересечений и откат |
| `sketchup_raycast` | Первое пересечение луча с видимой геометрией |

`sketchup_raycast` принимает `origin_mm` и `direction`: массивы из трёх чисел.
Направление должно быть ненулевым. Координаты ответа и расстояние — в мм.

## Подключение на этом компьютере

```powershell
codex mcp add sketchup-cj -- 'C:\Users\Golyatin.av\AppData\Local\Programs\Python\Python310\python.exe' 'C:\Users\Golyatin.av\Documents\ChatGPT\Skethcup инсоляция\tooling\mcp\server.py'
codex mcp get sketchup-cj
```

Настройки регистрируются в пользовательской конфигурации Codex. Пример записи
лежит в [config.example.toml](config.example.toml). Не нужно заменять весь config.toml.

14 октября 2026 сервер `sketchup-cj` зарегистрирован командой `mcp add`;
запись проверена в `C:/Users/Golyatin.av/.codex/config.toml`. В текущем чате
каталог инструментов сначала не обновился. После полного завершения приложения
через Диспетчер задач и повторного запуска все пять инструментов появились.
14 октября 2026 в 01:13 (Asia/Vladivostok) непосредственно из чата Codex успешно
вызваны `sketchup_status` и `sketchup_run_checks`: SketchUp отвечает, 7 проверок прошли.

Если новый сервер не появился в инструментах уже открытого чата, обновить серверы
в настройках MCP или перезапустить приложение. Сервер не запускает SketchUp сам.
После перезапуска SketchUp загрузить `tooling/sketchup_bridge.rb` через Ruby Console
как описано в [инструментарии](../README.md).

Сервер привязан к этому проекту, даже если его инструменты видны в другом проекте.
Геометрические тесты запускаются на текущей модели SketchUp: нужен свободный
тестовый сеанс вне режима редактирования группы/компонента. Перезагрузка плагина
исполняет доверенный код проекта. Настройки подтверждений Codex остаются в силе.

## Проверки

```powershell
python .\tooling\mcp\test_server.py
python .\tooling\mcp\test_server.py --live
```

Первый вариант проверяет протокол и искусственную очередь без SketchUp. Второй
дополнительно вызывает все пять инструментов в настоящем SketchUp, включая тест
с временной геометрией. Проверено 14 октября 2026: 18 проверок прошли.
Последний отчёт: `reports/mcp_check.json`.

Сервер реализует нужное подмножество MCP: initialize, initialized, ping,
tools/list, tools/call и уведомление отмены. Поддерживает версии 2025-06-18,
2025-03-26 и 2024-11-05. При более новой версии клиента предлагает 2025-06-18.
Resources, prompts и HTTP-транспорт не заявляются.

Отмена MCP прекращает ожидание и пытается пометить ещё не начатый запрос
просроченным. Уже исполняющийся Ruby-код она не прерывает. Ответы сохраняются
в `tooling/runtime`, чтобы проверить завершение перед повторным действием.

Отключение только MCP-сервера:

```powershell
codex mcp remove sketchup-cj
```

Это не удаляет исходники и не останавливает Ruby-мост в SketchUp.

## Источники

- [OpenAI: настройка MCP](https://learn.chatgpt.com/docs/extend/mcp?surface=cli).
- [MCP: STDIO](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports).
- [MCP: lifecycle](https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle).
- [MCP: tools](https://modelcontextprotocol.io/specification/2025-06-18/server/tools).
