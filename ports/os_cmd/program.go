package main

import (
	"bufio"
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
	writer            stdoutWriter
}

func startProgram(args []string, dir *string, terminateCmdParts arrayFlags, output stdoutWriter) (*program, error) {
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

	program := program{cmd, terminateCmdParts, reader, make(chan int), output}
	go func() {
		exitStatus := program.forwardOutput()
		program.writer.flush()
		program.exitStatus <- exitStatus
	}()

	return &program, nil
}

func (program program) forwardOutput() int {
	for {
		output := make([]byte, 1024)
		size, err := program.reader.Read(output)
		if err == nil {
			erlOutput := erlangTermBytes(tuple(atom("output"), erlangBinary{output[:size]}))
			program.writer.sendOutput(erlOutput)
		} else {
			break
		}
	}

	return program.awaitTermination()
}

func (program program) awaitTermination() int {
	err := program.cmd.Wait()
	if err == nil {
		return 0
	}

	exitError, ok := err.(*exec.ExitError)

	if ok {
		var waitStatus syscall.WaitStatus
		waitStatus = exitError.Sys().(syscall.WaitStatus)
		return waitStatus.ExitStatus()
	}
	return 1
}

func (program program) stop() {
	program.politeTerminate()
	program.cmd.Process.Kill()
}

func (program program) politeTerminate() {
	if len(program.terminateCmdParts) > 0 {
		program.invokeCustomTerminateCmd()
	} else {
		program.sendTermSignal()
	}
}

func (program program) sendTermSignal() {
	var signal syscall.Signal
	if runtime.GOOS == "windows" {
		signal = syscall.SIGKILL
	} else {
		signal = syscall.SIGTERM
	}

	err := program.cmd.Process.Signal(signal)
	if err == nil {
		time.Sleep(5 * time.Second)
	}
}

func (program program) invokeCustomTerminateCmd() {
	var terminateCmdPart arrayFlags
	terminateProgram, err := startProgram(program.terminateCmdParts, &program.cmd.Dir, terminateCmdPart, program.writer)
	if err != nil {
		return
	}

	select {
	case <-time.After(5 * time.Second):
		terminateProgram.cmd.Process.Kill()

	case <-terminateProgram.exitStatus:
	}
}
