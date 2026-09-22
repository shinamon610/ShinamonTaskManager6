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
        self.invoke("set", task_id, "progress", 2, 5, ok=False)
        self.assertEqual(self.invoke("get", task_id)["state"]["status"], "Done")
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

    def test_explicit_database_is_rejected(self):
        commands = [("graph", "explicit.sqlite3"), ("gets", "explicit.sqlite3"),
                    ("get", "explicit.sqlite3", 1),
                    ("set", "explicit.sqlite3", 1, "doing"),
                    ("set", "explicit.sqlite3", 1, "done"),
                    ("set", "explicit.sqlite3", 1, "done", "result"),
                    ("set", "explicit.sqlite3", 1, "progress", 1, 2)]
        for args in commands:
            self.invoke(*args, ok=False)
        self.config(self.cwd / "taskdb.json", "chosen.sqlite3")
        self.invoke("graph")
        before = self.invoke("gets")
        for args in commands:
            self.invoke(*args, ok=False)
        self.assertEqual(self.invoke("gets"), before)
        (self.cwd / "taskdb.json").write_text("invalid")
        for args in commands:
            self.invoke(*args, ok=False)
        self.assertFalse((self.cwd / "explicit.sqlite3").exists())

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

    def test_set_rejects_incomplete_dependencies_and_cycles(self):
        self.config(self.cwd / "taskdb.json", "chosen.sqlite3")
        self.invoke("graph")
        records = self.invoke("gets")
        for name in ["設計の見直し", "A", "B"]:
            task_id = next(row["id"] for row in records if row["name"] == name)
            for status in [("doing",), ("pending",), ("not-started",),
                           ("done", "rejected result"), ("progress", 1, 2)]:
                result = self.invoke("set", task_id, *status, ok=False)
                self.assertIn("requires completed dependency", result.stderr)
                self.assertEqual(self.invoke("gets"), records)

    def test_set_rejects_reopening_done_task(self):
        self.config(self.cwd / "taskdb.json", "chosen.sqlite3")
        self.invoke("graph")
        task_id = next(row["id"] for row in self.invoke("gets") if row["name"] == "設計")
        self.invoke("set", task_id, "doing")
        self.invoke("set", task_id, "pending")
        self.invoke("set", task_id, "not-started")
        self.invoke("set", task_id, "done", "keep")
        before = self.invoke("gets")
        for status in [("not-started",), ("doing",), ("pending",), ("progress", 1, 2)]:
            result = self.invoke("set", task_id, *status, ok=False)
            self.assertIn("already done", result.stderr)
            self.assertEqual(self.invoke("gets"), before)

    def test_set_rejects_absent_task_and_rolls_back_registration(self):
        self.config(self.cwd / "taskdb.json", "chosen.sqlite3")
        self.invoke("graph")
        records = self.invoke("gets")
        design = next(row["id"] for row in records if row["name"] == "設計")
        review = next(row["id"] for row in records if row["name"] == "設計の見直し")
        self.invoke("set", design, "done")
        before = self.invoke("gets")
        self.assertNotIn("実装", [row["name"] for row in before])
        result = self.invoke("set", review, "done", "rejected", ok=False)
        self.assertIn("not in the current graph", result.stderr)
        self.assertEqual(self.invoke("gets"), before)
        self.invoke("graph")
        implementation = next(row["id"] for row in self.invoke("gets")
                              if row["name"] == "実装")
        self.invoke("set", implementation, "doing")
        self.invoke("set", implementation, "progress", 1, 2)
        self.invoke("set", implementation, "done", "accepted")
        self.assertEqual(self.invoke("get", implementation)["state"]["result"], "accepted")

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

    def test_help_and_invalid_arguments_without_config(self):
        for args in [("--help",), ("-h",), ("--config", "missing.json", "--help")]:
            result = subprocess.run([str(BINARY), *args], cwd=self.cwd,
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Usage:", result.stdout)
        for args in [("get", "0"), ("get", "9223372036854775808"),
                     ("set", "1", "unknown"), ("set", "1", "progress", "3", "2"),
                     ("set", "1", "progress", "0", "0"),
                     ("set", "1", "progress", "-1", "2"),
                     ("set", "1", "done", "result", "extra"),
                     ("--config",), ("unknown",)]:
            self.invoke(*args, ok=False)
        self.assertFalse(list(self.cwd.glob("*.sqlite3")))


if __name__ == "__main__":
    unittest.main()
