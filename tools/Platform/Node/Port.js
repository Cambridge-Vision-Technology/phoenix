import net from "node:net";

export const createImpl = () => net.createServer();
export const listenImpl = (server) => (options) => (callback) => () => server.listen(options, callback);
export const addressImpl = (server) => () => server.address();
export const closeImpl = (server) => (callback) => () => server.close(callback);
export const errorImpl = (server) => (callback) => () => server.on("error", callback);
