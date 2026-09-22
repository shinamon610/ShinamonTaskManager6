"""Run after `lake build taskdb`; tests use isolated temporary databases."""
import json
from datetime import datetime, timezone
from pathlib import Path
import subprocess
import tempfile
import unittest


BINARY = Path(__file__).resolve().parents[1] / ".lake/build/bin/taskdb"


class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.cwd = Path(self.temp.name)

    def invoke(self, *args, ok=True):
        result = subprocess.run(
            [str(BINARY), *map(str, args)], cwd=self.cwd,
            text=True, capture_output=True,
        )
        self.assertEqual(result.returncode == 0, ok, result.stderr)
        return json.loads(result.stdout) if result.stdout.strip() and ok else result

    def config(self, path, database):
        path.write_text(json.dumps({"sqlitePath": str(database)}))

    def test_default_all_commands_and_config_reload(self):
        self.config(self.cwd / "taskdb.json", "chosen.sqlite3")
        self.invoke()  # No arguments also uses the config.
        self.assertTrue((self.cwd / "chosen.sqlite3").exists())
        self.assertFalse((self.cwd / "tasks.sqlite3").exists())
        records = self.invoke("gets")
        task_id = next(row["id"] for row in records if row["name"] == "設計")
        self.invoke("set", task_id, "done")
        self.assertEqual(self.invoke("get", task_id)["state"]["status"], "Done")
        self.invoke("graph")
        self.assertIn("実装", [row["name"] for row in self.invoke("gets")])
        self.invoke("set", task_id, "progress", 2, 5)
        self.assertNotEqual(self.invoke("get", task_id)["state"]["status"], "Done")
        previous = self.invoke("get", task_id)
        self.invoke("set-state", task_id, "state.json", ok=False)
        self.assertEqual(self.invoke("get", task_id), previous)
        self.config(self.cwd / "taskdb.json", "other.sqlite3")
        self.invoke("graph")
        self.assertEqual(self.invoke("get", task_id)["state"]["status"], "NotStarted")

    def test_explicit_config_relative_and_absolute_paths(self):
        directory = self.cwd / "config dir"
        directory.mkdir()
        config = directory / "custom.json"
        self.config(config, "relative.sqlite3")
        self.invoke("--config", config, "graph")
        self.assertTrue((directory / "relative.sqlite3").exists())
        self.assertFalse((self.cwd / "relative.sqlite3").exists())
        self.assertTrue(self.invoke("--config", config, "gets"))
        absolute = self.cwd / "absolute.sqlite3"
        self.config(config, absolute)
        self.invoke("--config", config, "graph")
        self.assertTrue(absolute.exists())

    def test_explicit_database_needs_no_config(self):
        self.invoke("graph", "explicit.sqlite3")
        task_id = self.invoke("gets", "explicit.sqlite3")[0]["id"]
        self.invoke("set", "explicit.sqlite3", task_id, "doing")
        self.assertEqual(self.invoke("get", "explicit.sqlite3", task_id)["state"]["status"], "Doing")
        (self.cwd / "taskdb.json").write_text("invalid")
        self.invoke("graph", "explicit.sqlite3")

    def test_done_result_and_automatic_completion_time(self):
        self.config(self.cwd / "taskdb.json", "chosen.sqlite3")
        self.invoke("graph")
        task_id = self.invoke("gets")[0]["id"]
        result = "動作確認済み '引用' と改行\n次の行"
        before = datetime.now(timezone.utc)
        self.invoke("set", task_id, "done", result)
        state = self.invoke("get", task_id)["state"]
        self.assertEqual(state["status"], "Done")
        self.assertEqual(state["result"], result)
        completed = datetime.fromisoformat(state["completedAt"].replace("Z", "+00:00"))
        self.assertLess(abs((completed - before).total_seconds()), 5)
        self.assertLessEqual(completed, datetime.now(timezone.utc))
        self.invoke("set", task_id, "done")
        self.assertEqual(self.invoke("get", task_id)["state"]["result"], result)
        self.invoke("set", "chosen.sqlite3", task_id, "done", "explicit DB result")
        self.assertEqual(self.invoke("get", task_id)["state"]["result"], "explicit DB result")
        self.invoke("set", task_id, "done", "")
        self.assertEqual(self.invoke("get", task_id)["state"]["result"], "")
        previous = self.invoke("gets")
        self.invoke("set", 99999, "done", "must not insert", ok=False)
        self.assertEqual(self.invoke("gets"), previous)

    def test_graph_includes_all_composed_tasks(self):
        self.config(self.cwd / "taskdb.json", "chosen.sqlite3")
        graph = self.invoke("graph")
        def names(nodes):
            return [name for node in nodes
                    for name in [node["name"], *names(node.get("dependents", []))]]
        self.assertIn("A", names(graph))
        self.assertIn("B", names(graph))
        self.assertIn("設計", names(graph))
        self.invoke("graph", "chosen.sqlite3", "cycle", ok=False)

    def test_bad_config_does_not_create_database(self):
        self.invoke("graph", ok=False)
        for text in ["invalid", "{}", '{"sqlitePath": 1}', '{"sqlitePath": ""}']:
            (self.cwd / "taskdb.json").write_text(text)
            self.invoke("graph", ok=False)
        self.assertFalse(list(self.cwd.glob("*.sqlite3")))
        self.config(self.cwd / "taskdb.json", "missing.sqlite3")
        self.invoke("gets", ok=False)
        self.invoke("get", 1, ok=False)
        self.invoke("set", 1, "done", ok=False)
        self.assertFalse((self.cwd / "missing.sqlite3").exists())


if __name__ == "__main__":
    unittest.main()
