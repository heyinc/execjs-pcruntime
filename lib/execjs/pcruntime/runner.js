const vm = require('vm');
let context = vm.createContext();
vm.runInContext(() => delete console, context);

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
                    const result = vm.runInContext(allData, context);
                    res.statusCode = 200;
                    res.setHeader('Content-Type', 'application/json');
                    res.end(JSON.stringify(result), 'utf-8');
                } catch (e) {
                    res.statusCode = 500;
                    res.setHeader('Content-Type', 'text/plain');
                    res.end(e.toString());
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
