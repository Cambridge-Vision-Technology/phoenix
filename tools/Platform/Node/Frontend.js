import ts from "typescript";
import { createRequire } from "node:module";

export const filesImpl = (root) => (excludes) => (includes) => () => ts.sys.readDirectory(root, undefined, excludes, includes);
export const importsImpl = (text) => () => ts.preProcessFile(text, true, true);
export const readConfigImpl = (path) => () => ts.readConfigFile(path, ts.sys.readFile);
export const parseConfigImpl = (config) => (root) => () => ts.parseJsonConfigFileContent(config, ts.sys, root);
export const resolveImpl = (name) => (file) => (options) => () => ts.resolveModuleName(name, file, options, ts.sys);
export const viteConfigImpl = (manifest) => (config) => () => createRequire(manifest)("vite").resolveConfig(config, "build", "production");
export const relayConfigImpl = (path) => () => createRequire(path)(path);
export const aliasPatternImpl = (alias) => () => alias.find.toString();
