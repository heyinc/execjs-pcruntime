const vm = require('vm');
let context = vm.createContext();
vm.runInContext("delete console;", context);

const http = require('http');
const server = http.createServer(function (req, res) {
    switch (req.url) {
        case '/':
            res.statusCode = 200;
            res.end();
            break;
        case '/eval':
            let allData = '';
            req.on('data', (data) => allData += data);
            req.on('end', () => {
                try {
                    // Percent-encoding HTTP requests and responses to avoid invalid UTF-8 sequences.
                    const result = vm.runInContext(decodeURIComponent(allData), context, "(execjs)");
                    res.statusCode = 200;
                    res.setHeader('Content-Type', 'application/json');
                    res.end(encodeURIComponent(JSON.stringify(result) || null));
                } catch (e) {
                    res.statusCode = 500;
                    res.setHeader('Content-Type', 'text/plain');
                    // to split by \0 on Ruby side
                    // see context_process_runtime.rb:179
                    res.end(encodeURIComponent(e.toString() + "\0" + (e.stack || "")));
                }
            });
            break;
        case '/exit':
            process.exit(0);
            break;
        default:
            console.log("Unknown Path");
            break;
    }
});

const port = process.env.PORT || 3001;
server.listen(port);
