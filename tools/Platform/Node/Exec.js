import process from "node:process";

export const execveImpl = (file) => (args) => (env) => () => process.execve(file, args, env);
