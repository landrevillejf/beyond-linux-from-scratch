#!/usr/bin/env python3
"""Tests for LPM interface mode selection."""

import sys

import pytest

import lpm


def test_parser_accepts_mode_cli_and_text():
    parser = lpm.create_parser()

    cli_args = parser.parse_args(['--mode', 'cli', 'list'])
    assert cli_args.mode == 'cli'
    assert cli_args.command == 'list'

    text_args = parser.parse_args(['--mode', 'text'])
    assert text_args.mode == 'text'


def test_parser_rejects_invalid_mode():
    parser = lpm.create_parser()
    with pytest.raises(SystemExit):
        parser.parse_args(['--mode', 'gui'])


def test_main_text_mode_starts_text_interface(monkeypatch, tmp_path):
    calls = {'text': 0, 'execute': 0}

    class DummyLPM:
        pass

    monkeypatch.setattr(lpm, 'LPM', lambda db_dir, verbose: DummyLPM())
    monkeypatch.setattr(lpm, 'run_text_interface', lambda manager: calls.__setitem__('text', calls['text'] + 1))
    monkeypatch.setattr(lpm, 'execute_command', lambda manager, args: calls.__setitem__('execute', calls['execute'] + 1))
    monkeypatch.setattr(sys, 'argv', ['lpm', '--mode', 'text', '--db-dir', str(tmp_path)])

    lpm.main()

    assert calls['text'] == 1
    assert calls['execute'] == 0


def test_main_text_mode_with_command_executes_directly(monkeypatch, tmp_path):
    calls = {'text': 0, 'execute': 0, 'command': None}

    class DummyLPM:
        pass

    monkeypatch.setattr(lpm, 'LPM', lambda db_dir, verbose: DummyLPM())
    monkeypatch.setattr(lpm, 'run_text_interface', lambda manager: calls.__setitem__('text', calls['text'] + 1))

    def fake_execute(_manager, args):
        calls['execute'] += 1
        calls['command'] = args.command

    monkeypatch.setattr(lpm, 'execute_command', fake_execute)
    monkeypatch.setattr(
        sys,
        'argv',
        ['lpm', '--mode', 'text', '--db-dir', str(tmp_path), 'list-installed']
    )

    lpm.main()

    assert calls['text'] == 0
    assert calls['execute'] == 1
    assert calls['command'] == 'list-installed'
