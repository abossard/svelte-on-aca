FROM node:18-alpine as build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM node:18-alpine as deploy

WORKDIR /app
COPY --from=build /app/build ./build
COPY --from=build /app/package.json ./build

RUN npm install dotenv
EXPOSE 3000
CMD ["node", "-r", "dotenv/config", "build"]
