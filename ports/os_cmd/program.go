package main

import (
	"bufio"
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"syscall"
	"time"
)

type program struct {
	cmd               *exec.Cmd
	terminateCmdParts arrayFlags
	reader            *bufio.Reader
	exitStatus        chan int
}

func startProgram(args []string, dir *string, terminateCmdParts arrayFlags) (*program, error) {
	cmd := exec.Command(args[0], args[1:]...)
	stdoutPipe, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}

	reader := bufio.NewReader(stdoutPipe)
	cmd.Stderr = cmd.Stdout
	cmd.Dir = *dir

	err = cmd.Start()
	if err != nil {
		return nil, err
	}

	program := &program{cmd: cmd, reader: reader, terminateCmdParts: terminateCmdParts, exitStatus: make(chan int)}
	go program.awaitCommand()
	return program, nil
}

func (program *program) awaitCommand() {
	for {
		s, err := program.reader.ReadString('\n')
		if err == nil {
			sendOutput([]byte(s))
		} else {
			break
		}
	}

	err := program.cmd.Wait()
	if err != nil {
		exitError, ok := err.(*exec.ExitError)

		if ok {
			var waitStatus syscall.WaitStatus
			waitStatus = exitError.Sys().(syscall.WaitStatus)
			program.exitStatus <- waitStatus.ExitStatus()
		} else {
			program.exitStatus <- 1
		}
	} else {
		program.exitStatus <- 0
	}
}

func (program *program) stop() {
	exitStatus, err := program.politeTerminate()
	if err == nil {
		os.Exit(exitStatus)
	}

	program.cmd.Process.Kill()
	exitStatus = <-program.exitStatus
	os.Exit(exitStatus)
}

func (program *program) politeTerminate() (int, error) {
	if len(program.terminateCmdParts) > 0 {
		return program.invokeCustomTerminateCmd()
	}

	var signal syscall.Signal
	if runtime.GOOS == "windows" {
		signal = syscall.SIGKILL
	} else {
		signal = syscall.SIGTERM
	}

	err := program.cmd.Process.Signal(signal)
	if err != nil {
		return -1, err
	}

	return program.awaitTermination()
}

func (program *program) invokeCustomTerminateCmd() (int, error) {
	terminateCmd := exec.Command(program.terminateCmdParts[0], program.terminateCmdParts[1:]...)
	terminateCmd.Dir = program.cmd.Dir

	var buf bytes.Buffer
	terminateCmd.Stdout = &buf
	terminateCmd.Stderr = &buf

	err := terminateCmd.Start()
	if err != nil {
		return -1, err
	}

	go func() {
		terminateCmd.Wait()
		sendOutput(buf.Bytes())
	}()

	return program.awaitTermination()
}

func (program *program) awaitTermination() (int, error) {
	select {
	case exit := <-program.exitStatus:
		return exit, nil

	case <-time.After(5 * time.Second):
		return -1, fmt.Errorf("timeout")
	}
}
