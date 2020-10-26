package main

import (
	"bufio"
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"
)

type program struct {
	cmd        *exec.Cmd
	killCmd    *string
	reader     *bufio.Reader
	exitStatus chan int
}

func startProgram(args []string, dir *string, killCmd *string) (*program, error) {
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

	program := &program{cmd: cmd, reader: reader, killCmd: killCmd, exitStatus: make(chan int)}
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
	if *program.killCmd != "" {
		fields := strings.Fields(*program.killCmd)
		killCmd := exec.Command(fields[0], fields[1:]...)
		killCmd.Dir = program.cmd.Dir

		var buf bytes.Buffer
		killCmd.Stdout = &buf
		killCmd.Stderr = &buf

		err := killCmd.Start()
		if err == nil {
			select {
			case exit := <-program.exitStatus:
				killCmd.Wait()
				sendOutput(buf.Bytes())
				os.Exit(exit)

			case <-time.After(5 * time.Second):
				sendOutput(buf.Bytes())
				killCmd.Process.Kill()
			}
		} else {
			sendOutput([]byte(fmt.Sprintf("%s", err)))
		}
	}

	// we end up here if kill command doesn't exist or it failed to kill the process
	program.cmd.Process.Kill()
	exit := <-program.exitStatus
	os.Exit(exit)
}
