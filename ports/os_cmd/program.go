package main

import (
	"bufio"
	"os/exec"
	"runtime"
	"syscall"
	"time"

	"github.com/creack/pty"
)

type program struct {
	cmd               *exec.Cmd
	terminateCmdParts arrayFlags
	reader            *bufio.Reader
	exitStatus        chan int
	writer            stdoutWriter
	usePty            *bool
}

func startProgram(args []string, dir *string, usePty *bool, terminateCmdParts arrayFlags, output stdoutWriter) (*program, error) {
	cmd := exec.Command(args[0], args[1:]...)
	cmd.Dir = *dir

	var reader *bufio.Reader
	var err error

	if *usePty {
		reader, err = startPty(cmd)
	} else {
		reader, err = startNormal(cmd)
	}

	if err != nil {
		return nil, err
	}

	program := program{cmd, terminateCmdParts, reader, make(chan int), output, usePty}
	go func() {
		exitStatus := program.forwardOutput()
		program.writer.flush()
		program.exitStatus <- exitStatus
	}()

	return &program, nil
}

func startPty(cmd *exec.Cmd) (*bufio.Reader, error) {
	reader, err := pty.Start(cmd)

	if err == pty.ErrUnsupported {
		return startNormal(cmd)
	}

	if err != nil {
		return nil, err
	}

	return bufio.NewReader(reader), nil
}

func startNormal(cmd *exec.Cmd) (*bufio.Reader, error) {
	stdoutPipe, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}

	reader := bufio.NewReader(stdoutPipe)
	cmd.Stderr = cmd.Stdout

	if runtime.GOOS != "windows" {
		// supports correct children termination on unix
		// (https://medium.com/@felixge/killing-a-child-process-and-all-of-its-children-in-go-54079af94773)
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	}

	err = cmd.Start()
	if err != nil {
		return nil, err
	}

	return reader, nil
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
	if runtime.GOOS != "windows" {
		// supports correct children termination on unix
		// (https://medium.com/@felixge/killing-a-child-process-and-all-of-its-children-in-go-54079af94773)
		syscall.Kill(-program.cmd.Process.Pid, syscall.SIGTERM)
	}

	// If the started program spawned its own processes which are now zombies, the main process will
	// be defunct, and won't stop. In this case we just give up and leave these zombies dangling.
	time.Sleep(1 * time.Second)
	program.exitStatus <- -1

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

	if runtime.GOOS != "windows" {
		// supports correct children termination on unix
		// (https://medium.com/@felixge/killing-a-child-process-and-all-of-its-children-in-go-54079af94773)
		syscall.Kill(-program.cmd.Process.Pid, syscall.SIGTERM)
	}

	if err == nil {
		time.Sleep(5 * time.Second)
	}
}

func (program program) invokeCustomTerminateCmd() {
	var terminateCmdPart arrayFlags
	terminateProgram, err := startProgram(program.terminateCmdParts, &program.cmd.Dir, program.usePty, terminateCmdPart, program.writer)
	if err != nil {
		return
	}

	select {
	case <-time.After(5 * time.Second):
		terminateProgram.cmd.Process.Kill()

	case <-terminateProgram.exitStatus:
	}
}
