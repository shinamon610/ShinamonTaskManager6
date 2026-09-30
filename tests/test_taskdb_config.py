"""Run after `lake build taskdb_tests`; tests use isolated temporary databases."""
import json
import csv
import os
from datetime import datetime, timezone
from pathlib import Path
import subprocess
import tempfile
import unittest


BINARY = Path(__file__).resolve().parents[1] / (".lake/build/bin/taskdb_tests.exe" if os.name == "nt" else ".lake/build/bin/taskdb_tests")


class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.cwd = Path(self.temp.name)

    def invoke(self, *args, ok=True):
        result = subprocess.run(
            [str(BINARY), "--cli", *map(str, args)], cwd=self.cwd,
            text=True, encoding="utf-8", capture_output=True,
        )
        self.assertEqual(result.returncode == 0, ok, result.stderr)
        return json.loads(result.stdout) if result.stdout.strip() and ok else result

    def config(self, path, database):
        path.write_text(json.dumps({"csvPath": str(database)}))

    def test_default_all_commands_and_config_reload(self):
        self.config(self.cwd / "taskdb.json", "chosen.csv")
        self.invoke()  # No arguments also uses the config.
        self.assertTrue((self.cwd / "chosen.csv").exists())
        self.assertFalse((self.cwd / "tasks.csv").exists())
        records = self.invoke("gets")
        design_record = next(row for row in records if row["name"] == "設計")
        self.assertEqual(design_record["name"], "設計")
        self.assertEqual(design_record["details"], "実装の方針を決める")
        self.assertEqual(set(design_record),
                         {"id", "name", "tags", "assign", "plannedStart", "plannedEnd", "details", "state"})
        task_id = next(row["id"] for row in records if row["name"] == "設計")
        self.invoke("set", task_id, "done")
        self.assertEqual(self.invoke("get", task_id)["state"]["status"], "Done")
        self.invoke("graph")
        self.assertIn("実装", [row["name"] for row in self.invoke("gets")])
        self.assertNotIn("設計の見直し", [row["name"] for row in self.invoke("gets")])
        self.invoke("set", task_id, "progress", 2, 5, ok=False)
        self.assertEqual(self.invoke("get", task_id)["state"]["status"], "Done")
        previous = self.invoke("get", task_id)
        self.invoke("set-state", task_id, "state.json", ok=False)
        self.assertEqual(self.invoke("get", task_id), previous)
        self.config(self.cwd / "taskdb.json", "other.csv")
        self.invoke("graph")
        fresh = next(row for row in self.invoke("gets") if row["name"] == "設計")
        self.assertEqual(fresh["state"]["status"], "NotStarted")

    def test_explicit_config_relative_and_absolute_paths(self):
        directory = self.cwd / "config dir"
        directory.mkdir()
        config = directory / "custom.json"
        self.config(config, "relative.csv")
        self.invoke("--config", config, "graph")
        self.assertTrue((directory / "relative.csv").exists())
        self.assertFalse((self.cwd / "relative.csv").exists())
        self.assertTrue(self.invoke("--config", config, "gets"))
        absolute = self.cwd / "absolute.csv"
        self.config(config, absolute)
        self.invoke("--config", config, "graph")
        self.assertTrue(absolute.exists())

    def test_explicit_database_is_rejected(self):
        commands = [("graph", "explicit.csv"), ("gets", "explicit.csv"),
                    ("get", "explicit.csv", 1),
                    ("set", "explicit.csv", 1, "doing"),
                    ("set", "explicit.csv", 1, "done"),
                    ("set", "explicit.csv", 1, "done", "result"),
                    ("set", "explicit.csv", 1, "progress", 1, 2)]
        for args in commands:
            self.invoke(*args, ok=False)
        self.config(self.cwd / "taskdb.json", "chosen.csv")
        self.invoke("graph")
        before = self.invoke("gets")
        for args in commands:
            self.invoke(*args, ok=False)
        self.assertEqual(self.invoke("gets"), before)
        (self.cwd / "taskdb.json").write_text("invalid")
        for args in commands:
            self.invoke(*args, ok=False)
        self.assertFalse((self.cwd / "explicit.csv").exists())

    def test_done_result_and_automatic_completion_time(self):
        self.config(self.cwd / "taskdb.json", "chosen.csv")
        self.invoke("graph")
        task_id = next(row["id"] for row in self.invoke("gets") if row["name"] == "設計")
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
        self.invoke("set", "!!!!!", "done", "must not insert", ok=False)
        self.assertEqual(self.invoke("gets"), previous)

    def test_graph_includes_all_composed_tasks(self):
        self.config(self.cwd / "taskdb.json", "chosen.csv")
        graph = self.invoke("graph")
        def names(nodes):
            return [name for node in nodes
                    for name in [node["name"], *names(node.get("dependents", []))]]
        self.assertIn("A", names(graph))
        self.assertIn("B", names(graph))
        self.assertIn("設計", names(graph))
        self.invoke("graph", "chosen.csv", "cycle", ok=False)

    def test_set_rejects_incomplete_dependencies_and_cycles(self):
        self.config(self.cwd / "taskdb.json", "chosen.csv")
        self.invoke("graph")
        records = self.invoke("gets")
        for name in ["設計の見直し", "A", "B"]:
            task_id = next(row["id"] for row in records if row["name"] == name)
            for status in [("doing",), ("pending",), ("ns",),
                           ("done", "rejected result"), ("progress", 1, 2)]:
                result = self.invoke("set", task_id, *status, ok=False)
                self.assertIn("requires completed dependency", result.stderr)
                self.assertEqual(self.invoke("gets"), records)

    def test_set_rejects_reopening_done_task(self):
        self.config(self.cwd / "taskdb.json", "chosen.csv")
        self.invoke("graph")
        task_id = next(row["id"] for row in self.invoke("gets") if row["name"] == "設計")
        self.invoke("set", task_id, "doing")
        self.invoke("set", task_id, "pending")
        self.invoke("set", task_id, "ns")
        self.invoke("set", task_id, "done", "keep")
        before = self.invoke("gets")
        for status in [("ns",), ("doing",), ("pending",), ("progress", 1, 2)]:
            result = self.invoke("set", task_id, *status, ok=False)
            self.assertIn("already done", result.stderr)
            self.assertEqual(self.invoke("gets"), before)

    def test_set_rejects_absent_task_and_rolls_back_registration(self):
        self.config(self.cwd / "taskdb.json", "chosen.csv")
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
        for text in ["invalid", "{}", '{"csvPath": 1}', '{"csvPath": ""}']:
            (self.cwd / "taskdb.json").write_text(text)
            self.invoke("graph", ok=False)
        self.assertFalse(list(self.cwd.glob("*.csv")))
        self.config(self.cwd / "taskdb.json", "missing.csv")
        self.invoke("gets", ok=False)
        self.invoke("get", "aaaaa", ok=False)
        self.invoke("set", "aaaaa", "done", ok=False)
        self.assertFalse((self.cwd / "missing.csv").exists())

    def read_csv(self):
        with (self.cwd / "chosen.csv").open(encoding="utf-8", newline="") as file:
            return list(csv.DictReader(file))

    def write_csv(self, rows):
        with (self.cwd / "chosen.csv").open("w", encoding="utf-8", newline="") as file:
            writer = csv.DictWriter(file, fieldnames=rows[0].keys())
            writer.writeheader()
            writer.writerows(rows)

    def test_csv_schema_and_state_updates(self):
        self.config(self.cwd / "taskdb.json", "chosen.csv")
        self.invoke("graph")
        rows = self.read_csv()
        self.assertEqual(set(rows[0]), {"id", "name", "tags", "assign", "plannedStart",
                         "plannedEnd", "details", "status", "progressCurrent", "progressTotal",
                         "completedAt", "result"})
        for row in rows:
            self.assertRegex(row["id"], r"^[a-z2-7]{5}$")
        self.assertEqual(len({row["id"] for row in rows}), len(rows))
        design = next(row["id"] for row in rows if row["name"] == "設計")
        self.invoke("set", design, "progress", 1, 2)
        row = next(row for row in self.read_csv() if row["id"] == design)
        self.assertEqual((row["status"], row["progressCurrent"], row["progressTotal"]),
                         ("Progress", "1", "2"))
        self.invoke("set", design, "doing")
        row = next(row for row in self.read_csv() if row["id"] == design)
        self.assertEqual((row["progressCurrent"], row["progressTotal"]), ("", ""))
        self.invoke("set", design, "done")
        self.invoke("graph")
        self.assertNotIn("設計の見直し", [row["name"] for row in self.read_csv()])
        self.assertEqual(next(row for row in self.read_csv() if row["id"] == design)["status"], "Done")
        self.assertFalse((self.cwd / "chosen.csv.tmp").exists())

    def test_csv_multiline_unicode_and_readonly_roundtrip(self):
        self.config(self.cwd / "taskdb.json", "chosen.csv")
        self.invoke("graph")
        rows = self.read_csv()
        row = next(row for row in rows if row["name"] == "設計")
        row["details"] = '詳細, "引用"\r\n次の行\n終わり'
        row["result"] = '結果, "\n\r\n'
        row["assign"] = json.dumps("")
        row["tags"] = json.dumps([{"url": 'https://example.com/?q="日本語",'}], ensure_ascii=False)
        self.write_csv(rows)
        before = (self.cwd / "chosen.csv").read_bytes()
        record = self.invoke("get", row["id"])
        self.assertEqual(record["details"], row["details"])
        self.assertEqual(record["state"]["result"], row["result"])
        self.assertEqual(record["assign"], "")
        self.assertEqual(record["tags"], json.loads(row["tags"]))
        self.invoke("gets")
        self.assertEqual((self.cwd / "chosen.csv").read_bytes(), before)
        self.invoke("set", row["id"], "done", row["result"])
        self.assertEqual(self.invoke("get", row["id"])["state"]["result"], row["result"])

    def test_invalid_csv_is_rejected_without_overwrite(self):
        self.config(self.cwd / "taskdb.json", "chosen.csv")
        self.invoke("graph")
        rows = self.read_csv()
        variants = []
        for field, value in [("id", "bad"), ("status", "invalid"), ("tags", "oops"),
                             ("assign", "oops"), ("completedAt", "42"),
                             ("progressCurrent", "1")]:
            modified = [dict(row) for row in rows]
            modified[0][field] = value
            variants.append(modified)
        for field in ["id", "name"]:
            modified = [dict(row) for row in rows]
            modified[1][field] = modified[0][field]
            variants.append(modified)
        for current, total in [("3", "2"), ("0", "0"), ("-1", "2"), ("", "2")]:
            modified = [dict(row) for row in rows]
            modified[0].update(status="Progress", progressCurrent=current, progressTotal=total)
            variants.append(modified)
        for variant in variants:
            self.write_csv(variant)
            before = (self.cwd / "chosen.csv").read_bytes()
            self.invoke("graph", ok=False)
            self.invoke("gets", ok=False)
            self.assertEqual((self.cwd / "chosen.csv").read_bytes(), before)
        for text in ["", "wrong,header\n", '\"unterminated',
                     (self.cwd / "chosen.csv").read_text(encoding="utf-8").splitlines()[0] + "\nx,y\n"]:
            (self.cwd / "chosen.csv").write_text(text, encoding="utf-8")
            before = (self.cwd / "chosen.csv").read_bytes()
            self.invoke("graph", ok=False)
            self.assertEqual((self.cwd / "chosen.csv").read_bytes(), before)

    def test_nested_storage_directory(self):
        self.config(self.cwd / "taskdb.json", "data/nested/tasks.csv")
        self.invoke("graph")
        self.assertTrue((self.cwd / "data/nested/tasks.csv").exists())

    def test_help_and_invalid_arguments_without_config(self):
        for args in [("--help",), ("-h",), ("--config", "missing.json", "--help")]:
            result = subprocess.run([str(BINARY), "--cli", *args], cwd=self.cwd,
                                    text=True, encoding="utf-8", capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Usage:", result.stdout)
        for args in [("get", "0"), ("get", "9223372036854775808"),
                     ("set", "aaaaa", "unknown"), ("set", "aaaaa", "progress", "3", "2"),
                     ("set", "aaaaa", "progress", "0", "0"),
                     ("set", "aaaaa", "progress", "-1", "2"),
                     ("set", "aaaaa", "done", "result", "extra"),
                     ("--config",), ("unknown",)]:
            self.invoke(*args, ok=False)
        self.assertFalse(list(self.cwd.glob("*.csv")))


if __name__ == "__main__":
    unittest.main()
