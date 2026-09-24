"""
Unit tests for container-compose.

These tests cover pure functions only — no container daemon or network required.
The CONTAINER_BIN env var is set to a known-good binary before import so the
module-level shutil.which() check passes without the real `container` CLI.
"""

import importlib.machinery
import importlib.util
import os
import sys
import unittest
from pathlib import Path

os.environ.setdefault("CONTAINER_BIN", "ls")

_script = str(Path(__file__).parent / "container-compose")
_loader = importlib.machinery.SourceFileLoader("container_compose", _script)
_spec = importlib.util.spec_from_loader("container_compose", _loader)
cc = importlib.util.module_from_spec(_spec)
_loader.exec_module(cc)


class TestParseJsonLines(unittest.TestCase):
    def test_empty_string(self):
        self.assertEqual(cc._parse_json_lines(""), [])

    def test_whitespace_only(self):
        self.assertEqual(cc._parse_json_lines("   \n  "), [])

    def test_json_array(self):
        self.assertEqual(cc._parse_json_lines('[{"id":"a"},{"id":"b"}]'), [{"id": "a"}, {"id": "b"}])

    def test_newline_delimited(self):
        text = '{"id":"a"}\n{"id":"b"}'
        self.assertEqual(cc._parse_json_lines(text), [{"id": "a"}, {"id": "b"}])

    def test_single_object(self):
        self.assertEqual(cc._parse_json_lines('{"id":"foo"}'), [{"id": "foo"}])

    def test_invalid_lines_are_skipped(self):
        text = '{"id":"a"}\nnot-json\n{"id":"b"}'
        self.assertEqual(cc._parse_json_lines(text), [{"id": "a"}, {"id": "b"}])


class TestAsList(unittest.TestCase):
    def test_none_returns_empty(self):
        self.assertEqual(cc._as_list(None), [])

    def test_list_passthrough(self):
        self.assertEqual(cc._as_list(["a", "b"]), ["a", "b"])

    def test_scalar_wrapped(self):
        self.assertEqual(cc._as_list("foo"), ["foo"])


class TestServiceContainerName(unittest.TestCase):
    def test_default_index(self):
        self.assertEqual(cc.service_container_name("proj", "web"), "proj-web-1")

    def test_custom_index(self):
        self.assertEqual(cc.service_container_name("proj", "worker", 3), "proj-worker-3")


class TestProjectName(unittest.TestCase):
    def setUp(self):
        self._orig = os.environ.pop("COMPOSE_PROJECT_NAME", None)

    def tearDown(self):
        if self._orig is not None:
            os.environ["COMPOSE_PROJECT_NAME"] = self._orig
        else:
            os.environ.pop("COMPOSE_PROJECT_NAME", None)

    def test_explicit_override(self):
        self.assertEqual(cc.project_name("custom", Path("docker-compose.yml")), "custom")

    def test_env_var(self):
        os.environ["COMPOSE_PROJECT_NAME"] = "from-env"
        self.assertEqual(cc.project_name(None, Path("docker-compose.yml")), "from-env")

    def test_cwd_fallback(self):
        name = cc.project_name(None, Path("docker-compose.yml"))
        self.assertEqual(name, Path(os.getcwd()).name)


class TestLabelValue(unittest.TestCase):
    def test_nested_configuration(self):
        c = {"configuration": {"labels": {"foo": "bar"}}}
        self.assertEqual(cc._label_value(c, "foo"), "bar")

    def test_top_level_labels(self):
        c = {"labels": {"foo": "bar"}}
        self.assertEqual(cc._label_value(c, "foo"), "bar")

    def test_missing_key_returns_none(self):
        c = {"configuration": {"labels": {}}}
        self.assertIsNone(cc._label_value(c, "missing"))

    def test_empty_container_returns_none(self):
        self.assertIsNone(cc._label_value({}, "foo"))


class TestOrderedServices(unittest.TestCase):
    def test_independent_services_all_returned(self):
        svcs = {"a": {}, "b": {}, "c": {}}
        self.assertEqual(set(cc.ordered_services(svcs, None)), {"a", "b", "c"})

    def test_dependency_precedes_dependent(self):
        svcs = {"web": {"depends_on": ["db"]}, "db": {}}
        order = cc.ordered_services(svcs, None)
        self.assertLess(order.index("db"), order.index("web"))

    def test_chain_ordering(self):
        svcs = {
            "app": {"depends_on": ["api"]},
            "api": {"depends_on": ["db"]},
            "db": {},
        }
        order = cc.ordered_services(svcs, None)
        self.assertLess(order.index("db"), order.index("api"))
        self.assertLess(order.index("api"), order.index("app"))

    def test_selected_subset(self):
        svcs = {"a": {}, "b": {}, "c": {}}
        order = cc.ordered_services(svcs, ["a", "c"])
        self.assertEqual(set(order), {"a", "c"})
        self.assertNotIn("b", order)

    def test_depends_on_as_dict(self):
        svcs = {
            "web": {"depends_on": {"db": {"condition": "service_started"}}},
            "db": {},
        }
        order = cc.ordered_services(svcs, None)
        self.assertLess(order.index("db"), order.index("web"))

    def test_no_duplicate_entries(self):
        svcs = {
            "a": {"depends_on": ["c"]},
            "b": {"depends_on": ["c"]},
            "c": {},
        }
        order = cc.ordered_services(svcs, None)
        self.assertEqual(len(order), len(set(order)))


class TestBuildRunArgs(unittest.TestCase):
    def _compose(self, networks=None, volumes=None):
        return {
            "networks": networks if networks is not None else {"default": {}},
            "volumes": volumes if volumes is not None else {},
        }

    def _args(self, svc, **kw):
        compose = kw.pop("compose", self._compose())
        return cc.build_run_args("proj", "web", svc, compose, **kw)

    # --- identity / name ---

    def test_starts_with_run(self):
        args = self._args({"image": "nginx:latest"})
        self.assertEqual(args[0], "run")

    def test_generated_name(self):
        args = self._args({"image": "nginx:latest"})
        idx = args.index("--name")
        self.assertEqual(args[idx + 1], "proj-web-1")

    def test_custom_container_name(self):
        args = self._args({"image": "nginx:latest", "container_name": "my-nginx"})
        idx = args.index("--name")
        self.assertEqual(args[idx + 1], "my-nginx")

    def test_image_appears(self):
        args = self._args({"image": "nginx:latest"})
        self.assertIn("nginx:latest", args)

    def test_image_defaults_to_project_service(self):
        args = self._args({"build": "."})
        self.assertIn("proj_web", args)

    # --- lifecycle flags ---

    def test_detach_true(self):
        self.assertIn("-d", self._args({"image": "x"}, detach=True))

    def test_detach_false(self):
        self.assertNotIn("-d", self._args({"image": "x"}, detach=False))

    def test_remove_on_exit(self):
        self.assertIn("--rm", self._args({"image": "x"}, remove_on_exit=True))

    # --- labels ---

    def test_project_label(self):
        args = self._args({"image": "x"})
        labels = [args[i + 1] for i, a in enumerate(args) if a == "-l"]
        self.assertIn(f"{cc.COMPOSE_LABEL_PROJECT}=proj", labels)

    def test_service_label(self):
        args = self._args({"image": "x"})
        labels = [args[i + 1] for i, a in enumerate(args) if a == "-l"]
        self.assertIn(f"{cc.COMPOSE_LABEL_SERVICE}=web", labels)

    def test_user_defined_labels(self):
        args = self._args({"image": "x", "labels": {"tier": "frontend"}})
        labels = [args[i + 1] for i, a in enumerate(args) if a == "-l"]
        self.assertIn("tier=frontend", labels)

    # --- environment ---

    def test_env_dict_key_value(self):
        args = self._args({"image": "x", "environment": {"FOO": "bar"}})
        idx = args.index("FOO=bar")
        self.assertEqual(args[idx - 1], "-e")

    def test_env_dict_none_value(self):
        args = self._args({"image": "x", "environment": {"KEY": None}})
        idx = args.index("KEY")
        self.assertEqual(args[idx - 1], "-e")

    def test_env_list(self):
        args = self._args({"image": "x", "environment": ["FOO=bar", "BAZ"]})
        self.assertIn("FOO=bar", args)
        self.assertIn("BAZ", args)

    # --- ports ---

    def test_ports(self):
        args = self._args({"image": "x", "ports": ["8080:80"]})
        self.assertIn("8080:80", args)

    # --- volumes ---

    def test_named_volume_prefixed(self):
        compose = self._compose(volumes={"data": {}})
        args = cc.build_run_args("proj", "redis", {"image": "redis", "volumes": ["data:/data"]}, compose)
        self.assertIn("proj_data:/data", args)

    def test_bind_mount_unchanged(self):
        args = self._args({"image": "x", "volumes": ["./src:/app"]})
        self.assertIn("./src:/app", args)

    def test_tmpfs_shorthand(self):
        args = self._args({"image": "x", "tmpfs": ["/run"]})
        self.assertIn("--tmpfs", args)
        self.assertIn("/run", args)

    # --- network ---

    def test_network_uses_project_prefix(self):
        compose = self._compose(networks={"frontend": {}})
        args = cc.build_run_args("proj", "web", {"image": "x", "networks": ["frontend"]}, compose)
        idx = args.index("--network")
        self.assertEqual(args[idx + 1], "proj_frontend")

    # --- resources ---

    def test_mem_limit(self):
        args = self._args({"image": "x", "mem_limit": "256m"})
        idx = args.index("--memory")
        self.assertEqual(args[idx + 1], "256m")

    def test_cpus(self):
        args = self._args({"image": "x", "cpus": 0.5})
        idx = args.index("--cpus")
        self.assertEqual(args[idx + 1], "0.5")

    def test_deploy_resource_limits(self):
        svc = {"image": "x", "deploy": {"resources": {"limits": {"memory": "512m", "cpus": "2.0"}}}}
        args = self._args(svc)
        self.assertIn("512m", args)
        self.assertIn("2.0", args)

    # --- entrypoint / command ---

    def test_entrypoint_string(self):
        args = self._args({"image": "x", "entrypoint": "/bin/sh"})
        idx = args.index("--entrypoint")
        self.assertEqual(args[idx + 1], "/bin/sh")

    def test_entrypoint_list_joined(self):
        args = self._args({"image": "x", "entrypoint": ["/bin/sh", "-c"]})
        idx = args.index("--entrypoint")
        self.assertEqual(args[idx + 1], "/bin/sh -c")

    def test_command_string_split(self):
        args = self._args({"image": "x", "command": "echo hello"})
        self.assertIn("echo", args)
        self.assertIn("hello", args)

    def test_command_list(self):
        args = self._args({"image": "x", "command": ["echo", "hello"]})
        self.assertIn("echo", args)

    def test_override_cmd_replaces_command(self):
        args = self._args({"image": "x", "command": "sleep 999"}, override_cmd=["echo", "hi"])
        self.assertIn("echo", args)
        self.assertNotIn("sleep", args)

    # --- capabilities ---

    def test_cap_add(self):
        args = self._args({"image": "x", "cap_add": ["NET_BIND_SERVICE"]})
        self.assertIn("--cap-add", args)
        self.assertIn("NET_BIND_SERVICE", args)

    def test_cap_drop(self):
        args = self._args({"image": "x", "cap_drop": ["ALL"]})
        self.assertIn("--cap-drop", args)
        self.assertIn("ALL", args)

    # --- other flags ---

    def test_working_dir(self):
        args = self._args({"image": "x", "working_dir": "/app"})
        idx = args.index("--workdir")
        self.assertEqual(args[idx + 1], "/app")

    def test_user(self):
        args = self._args({"image": "x", "user": "1000:1000"})
        idx = args.index("--user")
        self.assertEqual(args[idx + 1], "1000:1000")

    def test_read_only(self):
        self.assertIn("--read-only", self._args({"image": "x", "read_only": True}))

    def test_init(self):
        self.assertIn("--init", self._args({"image": "x", "init": True}))

    def test_tty(self):
        self.assertIn("-t", self._args({"image": "x", "tty": True}))

    def test_stdin_open(self):
        self.assertIn("-i", self._args({"image": "x", "stdin_open": True}))

    def test_shm_size(self):
        args = self._args({"image": "x", "shm_size": "64m"})
        self.assertIn("--shm-size", args)
        self.assertIn("64m", args)

    def test_dns(self):
        args = self._args({"image": "x", "dns": "8.8.8.8"})
        self.assertIn("--dns", args)
        self.assertIn("8.8.8.8", args)


if __name__ == "__main__":
    unittest.main()
